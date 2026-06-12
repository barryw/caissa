using System.Text.Json;
using System.Text.RegularExpressions;
using NLog;
using sim6502.Backend;
using sim6502.Proc;
using sim6502.Systems;

LogManager.Configuration = new NLog.Config.LoggingConfiguration();

try
{
    var options = BridgeOptions.Parse(args);
    using var bridge = new HeadlessBridge(options);
    bridge.Run();
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    return 2;
}

internal sealed record BridgeOptions(
    string ProgramPath,
    string SymbolsPath,
    string FindBestMoveLabel,
    bool StripHeader)
{
    public static BridgeOptions Parse(string[] args)
    {
        string? programPath = null;
        string? symbolsPath = null;
        var findBestMoveLabel = "ChessFindBestMove";
        var stripHeader = true;

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--program":
                    programPath = RequiredValue(args, ref i, arg);
                    break;
                case "--symbols":
                    symbolsPath = RequiredValue(args, ref i, arg);
                    break;
                case "--find-best-move":
                    findBestMoveLabel = RequiredValue(args, ref i, arg);
                    break;
                case "--no-strip-header":
                    stripHeader = false;
                    break;
                case "--help":
                    Console.Error.WriteLine(
                        "Usage: Sim6502HeadlessBridge --program tests/engine_harness.prg " +
                        "--symbols tests/engine_harness.sym [--find-best-move ChessFindBestMove]");
                    Environment.Exit(0);
                    break;
                default:
                    throw new ArgumentException($"Unknown argument: {arg}");
            }
        }

        if (programPath is null)
            throw new ArgumentException("--program is required");
        if (symbolsPath is null)
            throw new ArgumentException("--symbols is required");

        return new BridgeOptions(programPath, symbolsPath, findBestMoveLabel, stripHeader);
    }

    private static string RequiredValue(string[] args, ref int index, string optionName)
    {
        if (index + 1 >= args.Length)
            throw new ArgumentException($"{optionName} requires a value");
        index++;
        return args[index];
    }
}

internal sealed class HeadlessBridge : IDisposable
{
    private const int EmptyPiece = 0x30;
    private const int WhiteColor = 0x80;
    private const int NoEnPassant = 0xFF;
    private static readonly Regex SymbolRegex = new(@"^\.label\s+([A-Za-z_][A-Za-z0-9_]*)=\$([0-9A-Fa-f]+)\s*$", RegexOptions.Compiled);

    private readonly BridgeOptions _options;
    private readonly SimulatorBackend _backend;
    private readonly Dictionary<string, int> _symbols;
    private readonly byte[] _baselineMemory;
    private long _totalCycles;

    public HeadlessBridge(BridgeOptions options)
    {
        _options = options;
        _symbols = LoadSymbols(options.SymbolsPath);
        var (memoryMap, processorType) = MemoryMapFactory.CreateForSystem(SystemType.Generic6510);
        _backend = new SimulatorBackend(processorType, memoryMap);
        _backend.Processor.CycleCountIncrementedAction = () => _totalCycles++;
        LoadProgram(options.ProgramPath, options.StripHeader);
        _baselineMemory = _backend.Processor.DumpMemory().ToArray();
    }

    public void Run()
    {
        WriteJson(new
        {
            ready = true,
            emulator = "sim6502",
            processor = ProcessorType.MOS6510.ToString(),
            findBestMove = _options.FindBestMoveLabel,
        });

        string? line;
        while ((line = Console.In.ReadLine()) is not null)
        {
            if (string.IsNullOrWhiteSpace(line))
                continue;

            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            var id = GetOptionalInt(root, "id", 0);
            var command = GetOptionalString(root, "command", "bestmove");
            if (command == "quit")
            {
                WriteJson(new { id, ok = true, command = "quit" });
                break;
            }

            try
            {
                WriteJson(command switch
                {
                    "bestmove" => FindBestMove(id, root),
                    "ponder" => PonderSearch(id, root),
                    "ponderuse" => PonderUse(id, root),
                    _ => throw new InvalidOperationException($"Unknown command: {command}"),
                });
            }
            catch (Exception ex)
            {
                WriteJson(new
                {
                    id,
                    ok = false,
                    error = ex.Message,
                    pc = _backend.Processor.ProgramCounter,
                    cycles = _totalCycles,
                });
            }
        }
    }

    private object FindBestMove(int id, JsonElement root)
    {
        RestoreBaseline();
        var totalTimeout = GetOptionalLong(root, "timeoutCycles", 0);
        ExecuteRequiredRoutine("InitZobristTables", totalTimeout);
        ExecuteRequiredRoutine("TTClear", totalTimeout);
        WritePosition(root);

        var beforeSearchCycles = _totalCycles;
        var depthCycles = new Dictionary<string, long>();
        var depthAddress = _symbols.TryGetValue("SearchCompletedDepth", out var depthSymbol) ? depthSymbol : -1;
        var clean = ExecuteRoutine(Symbol(_options.FindBestMoveLabel), totalTimeout, () =>
        {
            if (depthAddress < 0)
                return;
            var depth = _backend.Processor.ReadMemoryValueWithoutCycle(depthAddress);
            if (depth > 0)
                depthCycles.TryAdd(depth.ToString(), _totalCycles - beforeSearchCycles);
        });
        var timedOut = RoutineTimedOut;
        var totalCycles = _totalCycles;
        var bestMoveFrom = ReadByte("BestMoveFrom");
        var bestMoveTo = ReadByte("BestMoveTo");

        // BestMoveFrom/To is scratch while root probes and partial iterations
        // run, so a timed-out search must answer with the engine's committed
        // pair: the best move of the last fully completed iteration. The
        // machine state is discarded by RestoreBaseline on the next request.
        if (timedOut)
        {
            bestMoveFrom = ReadByte("CommittedBestFrom");
            bestMoveTo = ReadByte("CommittedBestTo");
        }
        var encoded = (bestMoveFrom << 8) | bestMoveTo;

        return new
        {
            id,
            ok = clean || (timedOut && bestMoveFrom != 0xFF),
            timedOut,
            bestMoveFrom,
            bestMoveTo,
            encoded,
            cycles = totalCycles,
            searchCycles = totalCycles - beforeSearchCycles,
            searchDepth = TryReadByte("SearchDepth"),
            searchCompletedDepth = TryReadByte("SearchCompletedDepth"),
            searchRootMoveCount = TryReadByte("SearchRootMoveCount"),
            depthCycles,
            pc = _backend.Processor.ProgramCounter,
        };
    }

    private object PonderSearch(int id, JsonElement root)
    {
        RestoreBaseline();
        var totalTimeout = GetOptionalLong(root, "timeoutCycles", 0);
        ExecuteRequiredRoutine("InitZobristTables", totalTimeout);
        ExecuteRequiredRoutine("TTClear", totalTimeout);
        WritePosition(root);

        var predictedFrom = RequiredByte(root, "predictedFrom");
        var predictedTo = RequiredByte(root, "predictedTo");
        var processor = _backend.Processor;
        processor.Accumulator = (byte)predictedFrom;
        processor.XRegister = (byte)predictedTo;

        var beforeSearchCycles = _totalCycles;
        var clean = ExecuteRoutine(Symbol("ChessPonderSearch"), totalTimeout);
        var totalCycles = _totalCycles;
        var valid = ReadByte("PonderValid") != 0;
        var replyFrom = ReadByte("PonderReplyFrom");
        var replyTo = ReadByte("PonderReplyTo");
        var encoded = (replyFrom << 8) | replyTo;

        return new
        {
            id,
            ok = clean,
            valid,
            predictedFrom,
            predictedTo,
            replyFrom,
            replyTo,
            encoded,
            cycles = totalCycles,
            searchCycles = totalCycles - beforeSearchCycles,
            searchDepth = TryReadByte("SearchDepth"),
            searchCompletedDepth = TryReadByte("SearchCompletedDepth"),
            searchRootMoveCount = TryReadByte("SearchRootMoveCount"),
            pc = _backend.Processor.ProgramCounter,
        };
    }

    private object PonderUse(int id, JsonElement root)
    {
        var actualFrom = RequiredByte(root, "actualFrom");
        var actualTo = RequiredByte(root, "actualTo");
        var processor = _backend.Processor;
        processor.Accumulator = (byte)actualFrom;
        processor.XRegister = (byte)actualTo;

        var beforeCycles = _totalCycles;
        var clean = ExecuteRoutine(Symbol("ChessPonderUse"), GetOptionalLong(root, "timeoutCycles", 0));
        var totalCycles = _totalCycles;
        var accepted = processor.CarryFlag;
        var bestMoveFrom = ReadByte("BestMoveFrom");
        var bestMoveTo = ReadByte("BestMoveTo");
        var encoded = (bestMoveFrom << 8) | bestMoveTo;

        return new
        {
            id,
            ok = clean,
            accepted,
            actualFrom,
            actualTo,
            bestMoveFrom,
            bestMoveTo,
            encoded,
            cycles = totalCycles,
            useCycles = totalCycles - beforeCycles,
            pc = _backend.Processor.ProgramCounter,
        };
    }

    private void WritePosition(JsonElement root)
    {
        var board88 = ReadBoard88(root);
        var whiteKing = RequiredByte(root, "whitekingsq");
        var blackKing = RequiredByte(root, "blackkingsq");
        var whitePieces = BuildPieceList(board88, whiteKing, white: true);
        var blackPieces = BuildPieceList(board88, blackKing, white: false);

        if (whitePieces.Count > 16)
            throw new InvalidOperationException($"White piece list overflow: {whitePieces.Count}");
        if (blackPieces.Count > 16)
            throw new InvalidOperationException($"Black piece list overflow: {blackPieces.Count}");

        Fill("Board88", 128, EmptyPiece);
        for (var i = 0; i < board88.Length; i++)
            WriteByte(Symbol("Board88") + i, board88[i]);

        Fill("WhitePieceList", 16, 0xFF);
        Fill("BlackPieceList", 16, 0xFF);
        for (var i = 0; i < whitePieces.Count; i++)
            WriteByte(Symbol("WhitePieceList") + i, whitePieces[i]);
        for (var i = 0; i < blackPieces.Count; i++)
            WriteByte(Symbol("BlackPieceList") + i, blackPieces[i]);

        WriteByte("currentplayer", RequiredByte(root, "currentplayer"));
        WriteByte("difficulty", RequiredByte(root, "difficulty"));
        WriteByte("whitekingsq", whiteKing);
        WriteByte("blackkingsq", blackKing);
        WriteByte("castlerights", RequiredByte(root, "castlerights"));
        WriteByte("enpassantsq", RequiredByte(root, "enpassantsq"));
        WriteByte("HalfmoveClock", RequiredByte(root, "halfmoveClock"));

        var fullMove = GetOptionalInt(root, "fullmoveNumber", 1);
        WriteByte(Symbol("FullmoveNumber"), fullMove & 0xFF);
        WriteByte(Symbol("FullmoveNumber") + 1, (fullMove >> 8) & 0xFF);

        WriteByte("HistoryCount", 0);
        WriteByte("WhitePieceCount", whitePieces.Count);
        WriteByte("BlackPieceCount", blackPieces.Count);
        TryWriteByte("promotionsq", 0xFF);
        WriteByte("BestMoveFrom", 0xFF);
        WriteByte("BestMoveTo", 0xFF);
    }

    private static List<int> BuildPieceList(int[] board88, int kingSquare, bool white)
    {
        var pieces = new List<int> { kingSquare };
        for (var i = 0; i < board88.Length; i++)
        {
            var piece = board88[i];
            if (piece == EmptyPiece || i == kingSquare)
                continue;
            var isWhite = (piece & WhiteColor) != 0;
            if (isWhite == white)
                pieces.Add(i);
        }
        return pieces;
    }

    private void RestoreBaseline()
    {
        var memory = _backend.Processor.DumpMemory();
        Buffer.BlockCopy(_baselineMemory, 0, memory, 0, _baselineMemory.Length);
        _backend.Processor.Reset();
        _backend.Processor.Accumulator = 0;
        _backend.Processor.XRegister = 0;
        _backend.Processor.YRegister = 0;
        _backend.Processor.CarryFlag = false;
        _backend.Processor.ZeroFlag = false;
        _backend.Processor.DecimalFlag = false;
        _backend.Processor.OverflowFlag = false;
        _backend.Processor.NegativeFlag = false;
        _backend.Processor.DisableInterruptFlag = true;
        _totalCycles = 0;
        _backend.Processor.ResetCycleCount();
    }

    private bool ExecuteRequiredRoutine(string label, long timeoutCycles)
    {
        var clean = ExecuteRoutine(Symbol(label), timeoutCycles);
        if (!clean)
            throw new InvalidOperationException($"{label} exited via BRK");
        return clean;
    }

    private bool ExecuteRoutine(int address, long timeoutCycles, Action? onPoll = null)
    {
        var processor = _backend.Processor;
        var keepRunning = true;
        var subroutineCount = 1;
        var exitCleanly = true;
        var startCycles = _totalCycles;
        var steps = 0L;
        processor.ProgramCounter = address;

        RoutineTimedOut = false;

        do
        {
            if (processor.IsJsr())
                subroutineCount++;

            if (processor.IsRts())
            {
                subroutineCount--;
                if (subroutineCount == 0)
                {
                    keepRunning = false;
                    break;
                }
            }

            if (processor.IsBrk())
            {
                keepRunning = false;
                exitCleanly = false;
            }

            processor.NextStep();
            if (onPoll is not null && (++steps & 0x3FF) == 0)
                onPoll();

            if (timeoutCycles > 0 && _totalCycles - startCycles > timeoutCycles)
            {
                // The engine keeps BestMoveFrom/BestMoveTo current at the
                // root throughout iterative deepening, so a budget overrun
                // can still hand the caller the best move found so far
                // instead of failing the whole game. Callers that need a
                // hard failure can inspect the timedOut flag.
                RoutineTimedOut = true;
                keepRunning = false;
            }
        } while (keepRunning);

        return exitCleanly && !RoutineTimedOut;
    }

    private bool RoutineTimedOut;

    private void LoadProgram(string path, bool stripHeader)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length == 0)
            throw new InvalidOperationException($"Program is empty: {path}");

        var address = 0;
        var payload = bytes;
        if (stripHeader)
        {
            if (bytes.Length < 2)
                throw new InvalidOperationException($"PRG is missing a load address: {path}");
            address = bytes[0] | (bytes[1] << 8);
            payload = bytes[2..];
        }

        _backend.LoadBinary(payload, address);
    }

    private static Dictionary<string, int> LoadSymbols(string path)
    {
        var symbols = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var line in File.ReadLines(path))
        {
            var match = SymbolRegex.Match(line.Trim());
            if (!match.Success)
                continue;
            symbols[match.Groups[1].Value] = Convert.ToInt32(match.Groups[2].Value, 16);
        }
        return symbols;
    }

    private int Symbol(string name)
    {
        if (!_symbols.TryGetValue(name, out var address))
            throw new KeyNotFoundException($"Missing symbol: {name}");
        return address;
    }

    private int ReadByte(string label) => _backend.ReadByte(Symbol(label));

    private int? TryReadByte(string label)
    {
        return _symbols.ContainsKey(label) ? ReadByte(label) : null;
    }

    private void WriteByte(string label, int value) => WriteByte(Symbol(label), value);

    private bool TryWriteByte(string label, int value)
    {
        if (!_symbols.TryGetValue(label, out var address))
            return false;
        WriteByte(address, value);
        return true;
    }

    private void WriteByte(int address, int value)
    {
        _backend.WriteByte(address, (byte)(value & 0xFF));
    }

    private void Fill(string label, int length, int value)
    {
        var address = Symbol(label);
        for (var i = 0; i < length; i++)
            WriteByte(address + i, value);
    }

    private static int[] ReadBoard88(JsonElement root)
    {
        var boardElement = root.GetProperty("board88");
        if (boardElement.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException("board88 must be an array");
        var board = boardElement.EnumerateArray().Select(item => item.GetInt32() & 0xFF).ToArray();
        if (board.Length != 128)
            throw new InvalidOperationException($"board88 must contain 128 bytes, got {board.Length}");
        return board;
    }

    private static int RequiredByte(JsonElement root, string name)
    {
        var value = root.GetProperty(name).GetInt32();
        if (value < 0 || value > 0xFF)
            throw new InvalidOperationException($"{name} must be a byte: {value}");
        return value;
    }

    private static int GetOptionalInt(JsonElement root, string name, int fallback)
    {
        return root.TryGetProperty(name, out var value) ? value.GetInt32() : fallback;
    }

    private static long GetOptionalLong(JsonElement root, string name, long fallback)
    {
        return root.TryGetProperty(name, out var value) ? value.GetInt64() : fallback;
    }

    private static string GetOptionalString(JsonElement root, string name, string fallback)
    {
        return root.TryGetProperty(name, out var value) ? value.GetString() ?? fallback : fallback;
    }

    private static long NormalizeCycles(int cycles)
    {
        return cycles < 0 ? cycles + 4_294_967_296L : cycles;
    }

    private static void WriteJson(object value)
    {
        Console.WriteLine(JsonSerializer.Serialize(value));
        Console.Out.Flush();
    }

    public void Dispose()
    {
        _backend.Dispose();
    }
}
