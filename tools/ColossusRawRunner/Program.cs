using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using NLog;
using sim6502.Proc;
using sim6502.Systems;

LogManager.Configuration = new NLog.Config.LoggingConfiguration();

try
{
    var options = RawOptions.Parse(args);
    var runner = new RawRunner(options);
    runner.Run();
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    return 2;
}

internal sealed record RawOptions(
    string RamPath,
    string? MetaPath,
    string? CpuViewPath,
    string? JsonPath,
    string? ScreenPath,
    string? RamOutPath,
    int? ProgramCounter,
    string? Move,
    string? InputText,
    string? InputBytes,
    string? QueuedMove,
    string? QueuedText,
    string? QueuedInputBytes,
    string? MatrixText,
    IReadOnlyList<MemoryPoke> Pokes,
    long QueuedGapCycles,
    long MatrixHoldCycles,
    long MatrixGapCycles,
    long Cycles,
    long Steps,
    double WallTimeLimitSeconds,
    string? StopWhenScreenRegex,
    long PollSteps,
    long TodCyclesPerTick,
    bool StopOnBrk,
    bool EmitBestLineSamples)
{
    public static RawOptions Parse(string[] args)
    {
        string? ramPath = null;
        string? metaPath = null;
        string? cpuViewPath = null;
        string? jsonPath = null;
        string? screenPath = null;
        string? ramOutPath = null;
        int? pc = null;
        string? move = null;
        string? inputText = null;
        string? inputBytes = null;
        string? queuedMove = null;
        string? queuedText = null;
        string? queuedInputBytes = null;
        string? matrixText = null;
        var pokes = new List<MemoryPoke>();
        long queuedGapCycles = 250_000;
        long matrixHoldCycles = 300_000;
        long matrixGapCycles = 100_000;
        long cycles = 1_000_000;
        long steps = 0;
        double wallTimeLimitSeconds = 0.0;
        string? stopWhenScreenRegex = null;
        long pollSteps = 1024;
        long todCyclesPerTick = 100_000;
        var stopOnBrk = true;
        var emitBestLineSamples = false;

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--ram":
                    ramPath = RequiredValue(args, ref i, arg);
                    break;
                case "--meta":
                    metaPath = RequiredValue(args, ref i, arg);
                    break;
                case "--cpu-view":
                    cpuViewPath = RequiredValue(args, ref i, arg);
                    break;
                case "--json":
                    jsonPath = RequiredValue(args, ref i, arg);
                    break;
                case "--screen":
                    screenPath = RequiredValue(args, ref i, arg);
                    break;
                case "--ram-out":
                    ramOutPath = RequiredValue(args, ref i, arg);
                    break;
                case "--pc":
                    pc = ParseNumber(RequiredValue(args, ref i, arg));
                    break;
                case "--move":
                    move = RequiredValue(args, ref i, arg);
                    break;
                case "--input-text":
                    inputText = RequiredValue(args, ref i, arg);
                    break;
                case "--input-bytes":
                    inputBytes = RequiredValue(args, ref i, arg);
                    break;
                case "--queued-move":
                    queuedMove = RequiredValue(args, ref i, arg);
                    break;
                case "--queued-text":
                    queuedText = RequiredValue(args, ref i, arg);
                    break;
                case "--queued-input-bytes":
                    queuedInputBytes = RequiredValue(args, ref i, arg);
                    break;
                case "--queued-gap-cycles":
                    queuedGapCycles = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--matrix-text":
                    matrixText = RequiredValue(args, ref i, arg);
                    break;
                case "--poke":
                    pokes.Add(ParsePoke(RequiredValue(args, ref i, arg)));
                    break;
                case "--matrix-hold-cycles":
                    matrixHoldCycles = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--matrix-gap-cycles":
                    matrixGapCycles = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--cycles":
                    cycles = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--steps":
                    steps = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--wall-time-limit-seconds":
                    wallTimeLimitSeconds = ParseDouble(RequiredValue(args, ref i, arg));
                    break;
                case "--stop-when-screen-regex":
                    stopWhenScreenRegex = RequiredValue(args, ref i, arg);
                    break;
                case "--poll-steps":
                    pollSteps = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--tod-cycles-per-tick":
                    todCyclesPerTick = ParseLong(RequiredValue(args, ref i, arg));
                    break;
                case "--no-stop-on-brk":
                    stopOnBrk = false;
                    break;
                case "--emit-best-line-samples":
                    emitBestLineSamples = true;
                    break;
                case "--help":
                    Console.Error.WriteLine(
                        "Usage: ColossusRawRunner --ram ready.ram.bin [--meta ready.json] " +
                        "[--cycles 1000000] [--cycles 0 for no cycle cap] [--pc $6b6a] " +
                        "[--poke 0xb466=0xff] [--json out.json]");
                    Environment.Exit(0);
                    break;
                default:
                    throw new ArgumentException($"Unknown argument: {arg}");
            }
        }

        if (ramPath is null)
            throw new ArgumentException("--ram is required");
        return new RawOptions(
            ramPath,
            metaPath,
            cpuViewPath,
            jsonPath,
            screenPath,
            ramOutPath,
            pc,
            move,
            inputText,
            inputBytes,
            queuedMove,
            queuedText,
            queuedInputBytes,
            matrixText,
            pokes,
            Math.Max(0, queuedGapCycles),
            Math.Max(1, matrixHoldCycles),
            Math.Max(0, matrixGapCycles),
            cycles,
            steps,
            Math.Max(0.0, wallTimeLimitSeconds),
            stopWhenScreenRegex,
            Math.Max(1, pollSteps),
            Math.Max(1, todCyclesPerTick),
            stopOnBrk,
            emitBestLineSamples);
    }

    private static string RequiredValue(string[] args, ref int index, string optionName)
    {
        if (index + 1 >= args.Length)
            throw new ArgumentException($"{optionName} requires a value");
        index++;
        return args[index];
    }

    private static int ParseNumber(string text)
    {
        if (text.StartsWith("$", StringComparison.Ordinal))
            return Convert.ToInt32(text[1..], 16);
        if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            return Convert.ToInt32(text[2..], 16);
        return Convert.ToInt32(text, 10);
    }

    private static long ParseLong(string text)
    {
        if (text.StartsWith("$", StringComparison.Ordinal))
            return Convert.ToInt64(text[1..], 16);
        if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            return Convert.ToInt64(text[2..], 16);
        return Convert.ToInt64(text, 10);
    }

    private static double ParseDouble(string text) =>
        double.Parse(text, System.Globalization.CultureInfo.InvariantCulture);

    private static MemoryPoke ParsePoke(string text)
    {
        var separator = text.IndexOf('=');
        if (separator < 0)
            separator = text.IndexOf(':');
        if (separator <= 0 || separator == text.Length - 1)
            throw new ArgumentException($"--poke expects ADDRESS=VALUE, got {text}");

        var address = ParseNumber(text[..separator]);
        var value = ParseNumber(text[(separator + 1)..]);
        if (address < 0 || address > 0xFFFF)
            throw new ArgumentOutOfRangeException(nameof(text), $"poke address out of range: {text}");
        if (value < 0 || value > 0xFF)
            throw new ArgumentOutOfRangeException(nameof(text), $"poke value out of range: {text}");
        return new MemoryPoke(address, (byte)value);
    }
}

internal sealed record MemoryPoke(int Address, byte Value);

internal sealed record BestLineSample(
    long Cycles,
    long Steps,
    string Kind,
    int? Lookahead,
    long? Positions,
    string Line);

internal sealed class RawRunner
{
    private readonly RawOptions _options;
    private readonly Processor _processor;
    private long _totalCycles;

    public RawRunner(RawOptions options)
    {
        _options = options;
        var memoryMap = new ColossusMemoryMap(options.TodCyclesPerTick) { CycleSource = () => _totalCycles };
        _processor = new Processor(ProcessorType.MOS6510, memoryMap);
        _processor.CycleCountIncrementedAction = () => _totalCycles++;
    }

    public void Run()
    {
        var memory = File.ReadAllBytes(_options.RamPath);
        if (memory.Length != 0x10000)
            throw new InvalidOperationException($"--ram must be exactly 65536 bytes, got {memory.Length}");

        var memoryMap = (ColossusMemoryMap)_processor.MemoryMap!;
        memoryMap.LoadRamImage(memory);
        if (_options.CpuViewPath is not null)
        {
            var cpuView = File.ReadAllBytes(_options.CpuViewPath);
            if (cpuView.Length != 0x10000)
                throw new InvalidOperationException($"--cpu-view must be exactly 65536 bytes, got {cpuView.Length}");
            memoryMap.LoadCpuView(cpuView);
        }
        if (_options.MatrixText is not null)
            memoryMap.SetMatrixText(_options.MatrixText, _options.MatrixHoldCycles, _options.MatrixGapCycles);
        foreach (var poke in _options.Pokes)
            memoryMap.WriteWithoutCycle(poke.Address, poke.Value);
        InjectInput(memoryMap);
        var queuedInput = QueuedKeyboardInput.FromOptions(_options);
        ApplyRegisters(LoadRegisters());

        var start = SnapshotRegisters();
        var hasCycleLimit = _options.Cycles > 0;
        var maxCycles = hasCycleLimit ? _options.Cycles : long.MaxValue;
        var maxSteps = _options.Steps > 0 ? _options.Steps : long.MaxValue;
        var hasWallTimeLimit = _options.WallTimeLimitSeconds > 0.0;
        var stopRegex = _options.StopWhenScreenRegex is null
            ? null
            : new Regex(_options.StopWhenScreenRegex, RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.Multiline);
        var stopReason = "running";
        string? error = null;
        long steps = 0;
        var bestLineSamples = new List<BestLineSample>();
        string? lastBestLineSampleKey = null;
        var stopwatch = Stopwatch.StartNew();

        try
        {
            while (_totalCycles < maxCycles && steps < maxSteps)
            {
                queuedInput?.Pump(memoryMap, _totalCycles);
                if (_options.StopOnBrk && IsBrkAtPc())
                {
                    stopReason = "brk";
                    break;
                }
                _processor.NextStep();
                steps++;
                if (steps % _options.PollSteps == 0)
                {
                    string? polledScreen = null;
                    if (stopRegex is not null || _options.EmitBestLineSamples)
                    {
                        polledScreen = DecodeScreen(_processor.DumpMemory());
                        if (stopRegex is not null && stopRegex.IsMatch(polledScreen))
                        {
                            stopReason = "screen-regex";
                            break;
                        }
                        MaybeRecordBestLineSample(polledScreen, steps, bestLineSamples, ref lastBestLineSampleKey);
                    }
                    if (hasWallTimeLimit && stopwatch.Elapsed.TotalSeconds >= _options.WallTimeLimitSeconds)
                    {
                        stopReason = "wall-time-limit";
                        break;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            stopReason = "error";
            error = ex.Message;
        }
        stopwatch.Stop();

        if (stopReason == "running" && steps >= maxSteps)
            stopReason = "step-limit";
        else if (stopReason == "running" && hasCycleLimit && _totalCycles >= maxCycles)
            stopReason = "cycle-limit";
        else if (stopReason == "running" && hasWallTimeLimit && stopwatch.Elapsed.TotalSeconds >= _options.WallTimeLimitSeconds)
            stopReason = "wall-time-limit";

        var elapsedSeconds = Math.Max(stopwatch.Elapsed.TotalSeconds, 0.000001);

        var screen = DecodeScreen(_processor.DumpMemory());
        MaybeRecordBestLineSample(screen, steps, bestLineSamples, ref lastBestLineSampleKey, emit: false);
        if (_options.ScreenPath is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_options.ScreenPath))!);
            File.WriteAllText(_options.ScreenPath, screen + "\n");
        }

        if (_options.RamOutPath is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_options.RamOutPath))!);
            File.WriteAllBytes(_options.RamOutPath, _processor.DumpMemory());
        }

        var result = new
        {
            ok = error is null,
            error,
            stopReason,
            cycleLimit = hasCycleLimit ? _options.Cycles : (long?)null,
            wallTimeLimitSeconds = hasWallTimeLimit ? _options.WallTimeLimitSeconds : (double?)null,
            cycles = _totalCycles,
            steps,
            wallMilliseconds = stopwatch.Elapsed.TotalMilliseconds,
            cyclesPerSecond = _totalCycles / elapsedSeconds,
            stepsPerSecond = steps / elapsedSeconds,
            stoppedOnBrk = _options.StopOnBrk && IsBrkAtPc(),
            pokes = _options.Pokes.Select(poke => new { address = poke.Address, value = poke.Value }).ToList(),
            tod = memoryMap.TodSnapshot(),
            start,
            end = SnapshotRegisters(),
            screen,
            screenMoves = ParseScreenMoves(screen),
            bestLineSamples = bestLineSamples.Select(sample => new
            {
                cycles = sample.Cycles,
                steps = sample.Steps,
                kind = sample.Kind,
                lookahead = sample.Lookahead,
                positions = sample.Positions,
                line = sample.Line,
            }).ToList(),
        };

        if (_options.JsonPath is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_options.JsonPath))!);
            File.WriteAllText(_options.JsonPath, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }) + "\n");
        }

        Console.WriteLine(JsonSerializer.Serialize(result));
        if (error is not null)
            Environment.ExitCode = 1;
    }

    private void MaybeRecordBestLineSample(
        string screen,
        long steps,
        List<BestLineSample> samples,
        ref string? lastSampleKey,
        bool emit = true)
    {
        var (lookahead, positions) = ParseSearchStats(screen);
        var kind = "best";
        var line = ExtractLineAfterLabel(screen, "Best line");
        if (string.IsNullOrWhiteSpace(line))
        {
            kind = "current";
            line = ExtractLineAfterLabel(screen, "Current line");
        }
        line = NormalizeLine(line);
        if (line.Length == 0)
            return;

        var sampleKey = $"{kind}|{lookahead}|{line}";
        if (sampleKey == lastSampleKey)
            return;
        lastSampleKey = sampleKey;

        var sample = new BestLineSample(_totalCycles, steps, kind, lookahead, positions, line);
        samples.Add(sample);
        if (emit && _options.EmitBestLineSamples)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                type = "best-line-sample",
                cycles = sample.Cycles,
                steps = sample.Steps,
                kind = sample.Kind,
                lookahead = sample.Lookahead,
                positions = sample.Positions,
                line = sample.Line,
            }));
            Console.Out.Flush();
        }
    }

    private static (int? Lookahead, long? Positions) ParseSearchStats(string screen)
    {
        var match = Regex.Match(screen, @"Lookahead=(\d+)\s+Positions=([0-9]+)", RegexOptions.IgnoreCase);
        if (!match.Success)
            return (null, null);
        return (int.Parse(match.Groups[1].Value), long.Parse(match.Groups[2].Value));
    }

    private static string ExtractLineAfterLabel(string screen, string label)
    {
        var lines = screen.Split('\n');
        for (var index = 0; index < lines.Length - 1; index++)
        {
            if (lines[index].TrimStart().StartsWith(label, StringComparison.OrdinalIgnoreCase))
                return lines[index + 1].Trim();
        }
        return "";
    }

    private static string NormalizeLine(string line)
    {
        return Regex.Replace(line.Trim(), @"\s+", " ");
    }

    private Dictionary<string, JsonElement> LoadRegisters()
    {
        if (_options.MetaPath is null || !File.Exists(_options.MetaPath))
            return new Dictionary<string, JsonElement>();

        using var doc = JsonDocument.Parse(File.ReadAllText(_options.MetaPath));
        if (!doc.RootElement.TryGetProperty("registers", out var registers) &&
            !doc.RootElement.TryGetProperty("end", out registers))
            return new Dictionary<string, JsonElement>();

        return registers.EnumerateObject().ToDictionary(item => item.Name, item => item.Value.Clone(), StringComparer.OrdinalIgnoreCase);
    }

    private void ApplyRegisters(Dictionary<string, JsonElement> registers)
    {
        var pc = _options.ProgramCounter ?? ReadInt(registers, "PC", 0);
        _processor.ProgramCounter = pc;
        _processor.Accumulator = ReadInt(registers, "A", 0);
        _processor.XRegister = ReadInt(registers, "X", 0);
        _processor.YRegister = ReadInt(registers, "Y", 0);
        _processor.StackPointer = ReadInt(registers, "SP", 0xFD);
        _processor.CarryFlag = ReadBool(registers, "C", false);
        _processor.ZeroFlag = ReadBool(registers, "Z", false);
        _processor.NegativeFlag = ReadBool(registers, "N", false);
        _processor.OverflowFlag = ReadBool(registers, "V", false);
        _processor.DecimalFlag = ReadBool(registers, "D", false);
        _processor.DisableInterruptFlag = ReadBool(registers, "I", true);
        _processor.ResetCycleCount();
        _totalCycles = 0;
    }

    private object SnapshotRegisters() => new
    {
        PC = _processor.ProgramCounter,
        A = _processor.Accumulator & 0xFF,
        X = _processor.XRegister & 0xFF,
        Y = _processor.YRegister & 0xFF,
        SP = _processor.StackPointer & 0xFF,
        C = _processor.CarryFlag,
        Z = _processor.ZeroFlag,
        N = _processor.NegativeFlag,
        V = _processor.OverflowFlag,
        D = _processor.DecimalFlag,
        I = _processor.DisableInterruptFlag,
    };

    private bool IsBrkAtPc() => _processor.MemoryMap!.ReadWithoutCycle(_processor.ProgramCounter) == 0x00;

    private void InjectInput(ColossusMemoryMap memoryMap)
    {
        var text = _options.InputText;
        if (_options.Move is not null)
            text = ColossusMoveText(_options.Move);
        var bytes = _options.InputBytes is not null
            ? ParseByteList(_options.InputBytes)
            : text?.Select(ch => ch == '\n' ? 0x0D : ch & 0xFF).ToArray();
        if (bytes is null)
            return;

        if (bytes.Length > 10)
            throw new InvalidOperationException($"C64 keyboard buffer accepts at most 10 bytes, got {bytes.Length}");
        memoryMap.WriteWithoutCycle(0x00C6, (byte)bytes.Length);
        for (var i = 0; i < bytes.Length; i++)
            memoryMap.WriteWithoutCycle(0x0277 + i, (byte)bytes[i]);
    }

    private static string ColossusMoveText(string move)
    {
        var normalized = move.Trim().ToLowerInvariant();
        if (normalized.Length < 4)
            throw new ArgumentException($"expected UCI-like move such as e2e4, got {move}");
        return $"{normalized[1]}{char.ToUpperInvariant(normalized[0])}\n" +
               $"{normalized[3]}{char.ToUpperInvariant(normalized[2])}\n";
    }

    private static int[] ParseByteList(string text)
    {
        return text
            .Split(new[] { ',', ' ', ':' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(ParseByte)
            .ToArray();
    }

    private static int ParseByte(string text)
    {
        var value = text.StartsWith("$", StringComparison.Ordinal)
            ? Convert.ToInt32(text[1..], 16)
            : text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                ? Convert.ToInt32(text[2..], 16)
                : Convert.ToInt32(text, 16);
        if (value < 0 || value > 0xFF)
            throw new ArgumentOutOfRangeException(nameof(text), $"keyboard byte out of range: {text}");
        return value;
    }

    private static int ReadInt(Dictionary<string, JsonElement> values, string name, int fallback)
    {
        if (!values.TryGetValue(name, out var value))
            return fallback;
        return value.ValueKind == JsonValueKind.Number ? value.GetInt32() : fallback;
    }

    private static bool ReadBool(Dictionary<string, JsonElement> values, string name, bool fallback)
    {
        if (!values.TryGetValue(name, out var value))
            return fallback;
        return value.ValueKind == JsonValueKind.True || (value.ValueKind != JsonValueKind.False && fallback);
    }

    private static string DecodeScreen(byte[] memory)
    {
        var rows = new List<string>();
        for (var row = 0; row < 25; row++)
        {
            var chars = new char[40];
            for (var column = 0; column < 40; column++)
            {
                chars[column] = DecodeScreenCode(memory[0x0400 + row * 40 + column] & 0x7F);
            }
            rows.Add(new string(chars).TrimEnd());
        }
        return string.Join('\n', rows).TrimEnd();
    }

    private static List<string> ParseScreenMoves(string screen)
    {
        var moves = new List<string>();
        var regex = new Regex(
            @"^\s*\d+\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])[+#]?(?:\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])[+#]?)?",
            RegexOptions.IgnoreCase);
        foreach (var line in screen.Split('\n'))
        {
            var match = regex.Match(line);
            if (!match.Success)
                continue;
            moves.Add((match.Groups[1].Value + match.Groups[2].Value).ToLowerInvariant());
            if (match.Groups[3].Success && match.Groups[4].Success)
                moves.Add((match.Groups[3].Value + match.Groups[4].Value).ToLowerInvariant());
        }
        return moves;
    }

    private static char DecodeScreenCode(int value)
    {
        if (value == 0x0D)
            return '\n';
        if (value == 0x20)
            return ' ';
        if (value >= 0x30 && value <= 0x39)
            return (char)value;
        if (value >= 0x01 && value <= 0x1A)
            return (char)('a' + value - 1);
        if (value >= 0x21 && value <= 0x5A)
            return (char)value;
        return '.';
    }
}

internal sealed class QueuedKeyboardInput
{
    private readonly byte[] _bytes;
    private readonly long _gapCycles;
    private int _index;
    private long _nextCycle;

    private QueuedKeyboardInput(byte[] bytes, long gapCycles)
    {
        _bytes = bytes;
        _gapCycles = Math.Max(0, gapCycles);
    }

    public static QueuedKeyboardInput? FromOptions(RawOptions options)
    {
        var text = options.QueuedText;
        if (options.QueuedMove is not null)
            text = ColossusMoveText(options.QueuedMove);
        var bytes = options.QueuedInputBytes is not null
            ? ParseByteList(options.QueuedInputBytes).Select(value => (byte)value).ToArray()
            : text?.Select(ch => (byte)(ch == '\n' ? 0x0D : ch & 0xFF)).ToArray();
        return bytes is { Length: > 0 } ? new QueuedKeyboardInput(bytes, options.QueuedGapCycles) : null;
    }

    public void Pump(ColossusMemoryMap memoryMap, long cycle)
    {
        while (_index < _bytes.Length && cycle >= _nextCycle)
        {
            if (!memoryMap.TryEnqueueKeyboardByte(_bytes[_index]))
                return;
            _index++;
            _nextCycle += _gapCycles;
        }
    }

    private static string ColossusMoveText(string move)
    {
        var normalized = move.Trim().ToLowerInvariant();
        if (normalized.Length < 4)
            throw new ArgumentException($"expected UCI-like move such as e2e4, got {move}");
        return $"{normalized[1]}{char.ToUpperInvariant(normalized[0])}\n" +
               $"{normalized[3]}{char.ToUpperInvariant(normalized[2])}\n";
    }

    private static int[] ParseByteList(string text)
    {
        return text
            .Split(new[] { ',', ' ', ':' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(ParseByte)
            .ToArray();
    }

    private static int ParseByte(string text)
    {
        var value = text.StartsWith("$", StringComparison.Ordinal)
            ? Convert.ToInt32(text[1..], 16)
            : text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                ? Convert.ToInt32(text[2..], 16)
                : Convert.ToInt32(text, 16);
        if (value < 0 || value > 0xFF)
            throw new ArgumentOutOfRangeException(nameof(text), $"keyboard byte out of range: {text}");
        return value;
    }
}

internal sealed class ColossusMemoryMap : IMemoryMap
{
    private byte[] _ram = new byte[0x10000];
    private byte[] _basicRom = new byte[0x2000];
    private byte[] _kernalRom = new byte[0x2000];
    private byte[] _charRom = new byte[0x1000];
    private byte[] _io = new byte[0x1000];
    private byte _dataDirection;
    private byte _dataPort;
    private byte _cia1PortA = 0xFF;
    private byte _cia1PortB = 0xFF;
    private readonly long _todCyclesPerTick;
    private long _cycleTicks;
    private List<MatrixKeyWindow> _matrixWindows = new();

    public ColossusMemoryMap(long todCyclesPerTick)
    {
        _todCyclesPerTick = Math.Max(1, todCyclesPerTick);
    }

    public Action IncrementCycleCount { get; set; } = () => { };
    public Func<long>? CycleSource { get; set; }

    public byte Read(int address)
    {
        Tick();
        return ReadInternal(address);
    }

    public void Write(int address, byte value)
    {
        Tick();
        WriteInternal(address, value);
    }

    public byte ReadWithoutCycle(int address) => ReadInternal(address);

    public void WriteWithoutCycle(int address, byte value) => WriteInternal(address, value);

    public bool TryEnqueueKeyboardByte(byte value)
    {
        var length = ReadWithoutCycle(0x00C6);
        if (length >= 10)
            return false;
        WriteWithoutCycle(0x0277 + length, value);
        WriteWithoutCycle(0x00C6, (byte)(length + 1));
        return true;
    }

    public void LoadRom(string name, byte[] data)
    {
        switch (name.ToLowerInvariant())
        {
            case "basic":
                Array.Copy(data, 0, _basicRom, 0, Math.Min(data.Length, _basicRom.Length));
                break;
            case "kernal":
                Array.Copy(data, 0, _kernalRom, 0, Math.Min(data.Length, _kernalRom.Length));
                break;
            case "char":
            case "chargen":
                Array.Copy(data, 0, _charRom, 0, Math.Min(data.Length, _charRom.Length));
                break;
        }
    }

    public void LoadProgram(int address, byte[] data)
    {
        if (address + data.Length > _ram.Length)
            throw new InvalidOperationException($"program at ${address:X4} exceeds RAM");
        Array.Copy(data, 0, _ram, address, data.Length);
    }

    public byte[] GetRam() => _ram;

    public void LoadRamImage(byte[] data)
    {
        if (data.Length != _ram.Length)
            throw new InvalidOperationException($"RAM image must be 65536 bytes, got {data.Length}");
        Array.Copy(data, _ram, _ram.Length);
        _dataDirection = data[0x0000];
        _dataPort = data[0x0001];
        _cia1PortA = data[0xDC00];
        _cia1PortB = data[0xDC01];
    }

    public void LoadCpuView(byte[] data)
    {
        if (data.Length != _ram.Length)
            throw new InvalidOperationException($"CPU image must be 65536 bytes, got {data.Length}");
        _dataDirection = data[0x0000];
        _dataPort = data[0x0001];
        Array.Copy(data, 0xA000, _basicRom, 0, _basicRom.Length);
        Array.Copy(data, 0xD000, _io, 0, _io.Length);
        Array.Copy(data, 0xE000, _kernalRom, 0, _kernalRom.Length);
    }

    public void Reset()
    {
        _ram = new byte[0x10000];
        _basicRom = new byte[0x2000];
        _kernalRom = new byte[0x2000];
        _charRom = new byte[0x1000];
        _io = new byte[0x1000];
        _dataDirection = 0;
        _dataPort = 0;
        _cia1PortA = 0xFF;
        _cia1PortB = 0xFF;
        _cycleTicks = 0;
        _matrixWindows = new List<MatrixKeyWindow>();
    }

    public void SetMatrixText(string text, long holdCycles, long gapCycles)
    {
        var windows = new List<MatrixKeyWindow>();
        long start = 0;
        for (var index = 0; index < text.Length; index++)
        {
            var ch = text[index];
            if (ch == '\n')
            {
                start += gapCycles;
                continue;
            }
            var shifted = false;
            if (ch == '^')
            {
                if (index + 1 >= text.Length)
                    throw new ArgumentException("matrix text '^' must be followed by a key");
                shifted = true;
                ch = text[++index];
            }
            var (row, col) = MatrixKeyFor(ch);
            if (shifted)
                windows.Add(new MatrixKeyWindow(1, 7, start, start + holdCycles));
            windows.Add(new MatrixKeyWindow(row, col, start, start + holdCycles));
            start += holdCycles + gapCycles;
        }
        _matrixWindows = windows;
    }

    private byte ReadInternal(int address)
    {
        address &= 0xFFFF;
        if (address == 0x0000)
            return _dataDirection;
        if (address == 0x0001)
            return _dataPort;
        if (address is >= 0xDC08 and <= 0xDC0B)
            return ReadTod(address);
        if (address == 0xDC00)
            return MatrixPortA();
        if (address == 0xDC01)
            return MatrixPortB();

        if (address >= 0xA000 && address < 0xC000 && BasicVisible)
            return _basicRom[address - 0xA000];
        if (address >= 0xD000 && address < 0xE000)
        {
            if (!LoRam && !HiRam)
                return _ram[address];
            if (Charen)
                return _io[address - 0xD000];
            return _charRom[address - 0xD000];
        }
        if (address >= 0xE000 && HiRam)
            return _kernalRom[address - 0xE000];
        return _ram[address];
    }

    private void Tick()
    {
        IncrementCycleCount();
        _cycleTicks++;
    }

    private void WriteInternal(int address, byte value)
    {
        address &= 0xFFFF;
        switch (address)
        {
            case 0x0000:
                _dataDirection = value;
                _ram[address] = value;
                break;
            case 0x0001:
                _dataPort = value;
                _ram[address] = value;
                break;
            case 0xDC00:
                _cia1PortA = value;
                _io[address - 0xD000] = value;
                break;
            case 0xDC01:
                _cia1PortB = value;
                _io[address - 0xD000] = value;
                break;
            default:
                if (address >= 0xD000 && address < 0xE000 && (LoRam || HiRam) && Charen)
                    _io[address - 0xD000] = value;
                else
                    _ram[address] = value;
                break;
        }
    }

    private bool LoRam => (_dataPort & 0x01) != 0;
    private bool HiRam => (_dataPort & 0x02) != 0;
    private bool Charen => (_dataPort & 0x04) != 0;
    private bool BasicVisible => LoRam && HiRam;

    private byte MatrixPortA()
    {
        var value = _cia1PortA;
        foreach (var key in ActiveMatrixKeys())
        {
            if ((_cia1PortB & (1 << key.Col)) == 0)
                value = (byte)(value & ~(1 << key.Row));
        }
        return value;
    }

    private byte MatrixPortB()
    {
        var value = _cia1PortB;
        foreach (var key in ActiveMatrixKeys())
        {
            if ((_cia1PortA & (1 << key.Row)) == 0)
                value = (byte)(value & ~(1 << key.Col));
        }
        return value;
    }

    private IEnumerable<MatrixKeyWindow> ActiveMatrixKeys()
    {
        var cycle = CurrentCycle;
        foreach (var key in _matrixWindows)
        {
            if (cycle >= key.StartCycle && cycle < key.EndCycle)
                yield return key;
        }
    }

    private long CurrentCycle => CycleSource?.Invoke() ?? _cycleTicks;

    public object TodSnapshot()
    {
        var ticks = CurrentCycle / _todCyclesPerTick;
        var totalSeconds = ticks / 10;
        return new
        {
            cyclesPerTick = _todCyclesPerTick,
            ticks,
            tenths = ticks % 10,
            seconds = totalSeconds % 60,
            minutes = (totalSeconds / 60) % 60,
            hours = totalSeconds / 3600,
        };
    }

    private byte ReadTod(int address)
    {
        var ticks = CurrentCycle / _todCyclesPerTick;
        var totalSeconds = ticks / 10;
        return address switch
        {
            0xDC08 => (byte)(ticks % 10),
            0xDC09 => ToBcd(totalSeconds % 60),
            0xDC0A => ToBcd((totalSeconds / 60) % 60),
            0xDC0B => ToBcd((totalSeconds / 3600) % 100),
            _ => 0,
        };
    }

    private static byte ToBcd(long value)
    {
        value = Math.Clamp(value, 0, 99);
        return (byte)(((value / 10) << 4) | (value % 10));
    }

    private static (int Row, int Col) MatrixKeyFor(char ch)
    {
        var key = char.ToUpperInvariant(ch);
        if (key >= 'A' && key <= 'Z')
        {
            int[,] letters =
            {
                {1, 2}, {3, 4}, {2, 4}, {2, 2}, {1, 6}, {2, 5}, {3, 2}, {3, 5}, {4, 1},
                {4, 2}, {4, 5}, {5, 2}, {4, 4}, {4, 7}, {4, 6}, {5, 1}, {7, 6}, {2, 1},
                {1, 5}, {2, 6}, {3, 6}, {3, 7}, {1, 1}, {2, 7}, {3, 1}, {1, 4},
            };
            var index = key - 'A';
            return (letters[index, 0], letters[index, 1]);
        }
        if (key >= '0' && key <= '9')
        {
            int[,] numbers =
            {
                {4, 3}, {7, 0}, {7, 3}, {1, 0}, {1, 3}, {2, 0}, {2, 3}, {3, 0}, {3, 3}, {4, 0},
            };
            var index = key - '0';
            return (numbers[index, 0], numbers[index, 1]);
        }
        return key switch
        {
            ' ' => (7, 4),
            '\r' => (0, 1),
            _ => throw new ArgumentException($"No C64 matrix mapping for '{ch}'"),
        };
    }
}

internal sealed record MatrixKeyWindow(int Row, int Col, long StartCycle, long EndCycle);
