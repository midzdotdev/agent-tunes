// audio-watch: is any process other than ours playing audio?
//
// Uses CoreAudio's process-object API (macOS 14.4+): every audio client is an
// AudioObject with a PID and an "is running output" flag, so the answer is
// exact. An app merely holding an audio session open (Slack, Teams, an idle
// Safari tab) reports false. Only actual output counts.
//
// It polls, deliberately. CoreAudio also publishes change notifications for
// the process list and the running-output flag, but on macOS 25.6 those arrive
// roughly 33 seconds after the event, for a newly spawned process and for an
// already-registered one alike. That is no use when the job is to get out of
// the way now. One long-lived process doing about 60 local property reads twice
// a second costs roughly a millisecond a tick; measure it with `--bench`.
//
// Usage:  audio-watch [--once] [--interval <s>] [--sustain <s>] [--bench] <pid>...
//   default     block until another process sustains output
//   --once      check once and exit, without waiting
//   --sustain   how long the other process must keep playing before it counts,
//               which filters brief blips from short-lived processes.
//   --ignore-names
//               comma-separated executable names that never count, however long
//               they play. Defaults to systemsoundserverd, the daemon behind
//               notification chimes and system alerts.
//
// On the ignore list, and why --sustain alone is not enough: IsRunningOutput is
// sticky. A notification chime lasts about half a second, but systemsoundserverd
// was measured holding output "running" for up to 10.35 s afterwards on macOS
// 25.6. No sustain threshold can separate that from a real interruption, so the
// daemon is excluded by name instead.
//
// Exit codes:
//   0  another process is playing, and its pid is printed as "BUSY <pid>"
//   1  nothing else is playing (--once only)
//   3  the OS does not support the process-object API
//   4  the first ignored pid exited, so there is nothing left to guard

import CoreAudio
import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let once = args.contains("--once")
let bench = args.contains("--bench")
func option(_ name: String, _ fallback: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count,
          let v = Double(args[i + 1]) else { return fallback }
    return v
}
let interval = max(0.05, option("--interval", 0.5))
let sustain = max(0, option("--sustain", 1.0))

var ignoredNames: Set<String> = ["systemsoundserverd"]
if let i = args.firstIndex(of: "--ignore-names"), i + 1 < args.count {
    ignoredNames = Set(args[i + 1].split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
}

/// Executable name for a pid, cached: the same pids are re-checked every tick.
var nameCache: [pid_t: String] = [:]
func execName(_ p: pid_t) -> String {
    if let cached = nameCache[p] { return cached }
    var buf = [CChar](repeating: 0, count: 4096)
    let resolved = proc_pidpath(p, &buf, UInt32(buf.count)) > 0
        ? (String(cString: buf) as NSString).lastPathComponent : ""
    nameCache[p] = resolved
    return resolved
}

// Everything that is not a flag, and not a value belonging to one.
let valueFlags: Set<String> = ["--interval", "--sustain", "--ignore-names"]
let ignored = Set(
    args.indices
        .filter { !args[$0].hasPrefix("--") && ($0 == 0 || !valueFlags.contains(args[$0 - 1])) }
        .compactMap { pid_t(args[$0]) })

let system = AudioObjectID(kAudioObjectSystemObject)

var listAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var pidAddr = AudioObjectPropertyAddress(
    mSelector: kAudioProcessPropertyPID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var runningAddr = AudioObjectPropertyAddress(
    mSelector: kAudioProcessPropertyIsRunningOutput,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

func processObjects() -> [AudioObjectID] {
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func pid(of obj: AudioObjectID) -> pid_t {
    var value: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &size, &value) == noErr else { return -1 }
    return value
}

func isRunningOutput(_ obj: AudioObjectID) -> Bool {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &runningAddr, 0, nil, &size, &value) == noErr else { return false }
    return value != 0
}

/// The pid of a process we were not told to ignore that is producing output.
func offender(in objs: [AudioObjectID]) -> pid_t? {
    for obj in objs where isRunningOutput(obj) {
        let p = pid(of: obj)
        if p > 0 && !ignored.contains(p) && !ignoredNames.contains(execName(p)) { return p }
    }
    return nil
}

var objects = processObjects()
if objects.isEmpty {
    FileHandle.standardError.write(Data("audio-watch: process-object API unavailable\n".utf8))
    exit(3)
}

if bench {
    let start = Date()
    for _ in 0..<100 { _ = offender(in: processObjects()) }
    let ms = Date().timeIntervalSince(start) * 10  // /100 iterations, *1000 ms
    print(String(format: "%d objects, %.2f ms per full scan", objects.count, ms))
    exit(0)
}

if once {
    if let p = offender(in: objects) { print("BUSY \(p)"); exit(0) }
    exit(1)
}

let guarded = ignored.sorted().first
// The same process has to still be playing this many polls running.
let needed = max(1, Int((sustain / interval).rounded(.up)))
var streakPid: pid_t = 0
var streak = 0
var sinceRefresh = 0

while true {
    if let g = guarded, kill(g, 0) != 0 { exit(4) }  // our player has gone
    if let p = offender(in: objects) {
        streak = (p == streakPid) ? streak + 1 : 1
        streakPid = p
        if streak >= needed { print("BUSY \(p)"); exit(0) }
    } else {
        streak = 0
        streakPid = 0
    }
    // A new client means a new object, so refresh the list periodically rather
    // than on every tick. The list read is the expensive half of a scan.
    sinceRefresh += 1
    if sinceRefresh >= 4 {
        objects = processObjects()
        sinceRefresh = 0
    }
    Thread.sleep(forTimeInterval: interval)
}
