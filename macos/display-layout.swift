import CoreGraphics
import Foundation

struct DisplaySpec {
  let vendor: UInt32
  let model: UInt32
  let serial: UInt32

  init?(_ value: String) {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let vendor = UInt32(parts[0]), let model = UInt32(parts[1]),
      let serial = UInt32(parts[2])
    else { return nil }
    self.vendor = vendor
    self.model = model
    self.serial = serial
  }

  func matches(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == vendor && CGDisplayModelNumber(id) == model
      && CGDisplaySerialNumber(id) == serial
  }
}

enum LayoutError: Error {
  case missingDisplay
  case displayUnavailable
  case invalidDisplay(String)
  case graphics(CGError)
}

func check(_ result: CGError) throws {
  if result != .success { throw LayoutError.graphics(result) }
}

func onlineDisplays() throws -> [CGDirectDisplayID] {
  var count: UInt32 = 0
  try check(CGGetOnlineDisplayList(0, nil, &count))
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  try check(CGGetOnlineDisplayList(count, &ids, &count))
  return Array(ids.prefix(Int(count)))
}

func builtinDisplay(in ids: [CGDirectDisplayID]) throws -> CGDirectDisplayID {
  guard let id = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
    throw LayoutError.missingDisplay
  }
  return id
}

func displaySpecs(_ values: ArraySlice<String>) throws -> [DisplaySpec] {
  try values.map { value in
    guard let spec = DisplaySpec(value) else { throw LayoutError.invalidDisplay(value) }
    return spec
  }
}

func matchingDisplays(_ specs: [DisplaySpec], in ids: [CGDirectDisplayID]) -> [CGDirectDisplayID] {
  ids.filter { id in CGDisplayIsBuiltin(id) == 0 && specs.contains { $0.matches(id) } }
}

func configure(_ action: (CGDisplayConfigRef) throws -> Void) throws {
  var configuration: CGDisplayConfigRef?
  try check(CGBeginDisplayConfiguration(&configuration))
  guard let configuration else { throw LayoutError.displayUnavailable }
  do {
    try action(configuration)
    try check(CGCompleteDisplayConfiguration(configuration, .forSession))
  } catch {
    CGCancelDisplayConfiguration(configuration)
    throw error
  }
}

func makeMain(_ target: CGDirectDisplayID) throws {
  guard CGMainDisplayID() != target else { return }
  var count: UInt32 = 0
  try check(CGGetActiveDisplayList(0, nil, &count))
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  try check(CGGetActiveDisplayList(count, &ids, &count))
  let origin = CGDisplayBounds(target).origin
  try configure { configuration in
    for id in ids.prefix(Int(count)) {
      let position = CGDisplayBounds(id).origin
      try check(
        CGConfigureDisplayOrigin(
          configuration, id, Int32(position.x - origin.x), Int32(position.y - origin.y)))
    }
  }
}

func setMirroring(_ displays: [CGDirectDisplayID], source: CGDirectDisplayID) throws {
  let targets = displays.filter { CGDisplayMirrorsDisplay($0) != source }
  guard !targets.isEmpty else { return }
  try configure { configuration in
    for target in targets {
      try check(CGConfigureDisplayMirrorOfDisplay(configuration, target, source))
    }
  }
}

func usage() -> Never {
  fputs(
    "Usage: display-layout status | away DELAY DISPLAY... | desk MAIN_DISPLAY [DISPLAY...]\n",
    stderr)
  fputs("Display IDs use decimal vendor:model:serial; copy them from status.\n", stderr)
  exit(2)
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first {
  case "away":
    guard args.count >= 3, let delay = Double(args[1]), delay.isFinite, delay >= 0 else { usage() }
    let specs = try displaySpecs(args.dropFirst(2))
    Thread.sleep(forTimeInterval: delay)
    try makeMain(builtinDisplay(in: onlineDisplays()))
    let current = try onlineDisplays()
    try setMirroring(matchingDisplays(specs, in: current), source: builtinDisplay(in: current))
  case "desk":
    guard args.count >= 2 else { usage() }
    let specs = try displaySpecs(args.dropFirst())
    try setMirroring(matchingDisplays(specs, in: onlineDisplays()), source: kCGNullDirectDisplay)
    var ready = false
    for _ in 0..<20 {
      let current = try onlineDisplays()
      if let main = current.first(where: specs[0].matches), CGDisplayIsActive(main) != 0 {
        try makeMain(main)
        if specs.allSatisfy({ spec in
          current.contains(where: { spec.matches($0) && CGDisplayIsActive($0) != 0 })
        }) {
          ready = true
          break
        }
      }
      usleep(100_000)
    }
    if !ready { throw LayoutError.displayUnavailable }
  case "status":
    guard args.count == 1 else { usage() }
    for id in try onlineDisplays() {
      let identifier =
        "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
      let kind = CGDisplayIsBuiltin(id) != 0 ? "Built-in" : "External"
      print(
        "\(kind): \(identifier) main=\(id == CGMainDisplayID()) mirrorOf=\(CGDisplayMirrorsDisplay(id))"
      )
    }
  default:
    usage()
  }
} catch {
  fputs("display-layout: \(error)\n", stderr)
  exit(1)
}
