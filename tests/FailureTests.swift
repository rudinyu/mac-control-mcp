// Unit tests for the error result every failed mac-control call returns. Built with Sources/MacControl/Failure.swift
// and Sources/Shared/JSON.swift by scripts/ci.sh.

import Foundation

private var failures = 0

private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    if passed {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\(detail().isEmpty ? "" : "\n     \(detail())")")
    }
}

// The message and the error JSON of a failure's result, which has one text part, like a success.
private func parts(_ error: Error) -> (isError: Bool, message: String, error: [String: Any], partCount: Int) {
    let result = failureResult(error)
    let content = result["content"] as? [[String: Any]] ?? []
    let json = (content.first?["text"] as? String).flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let failure = json["error"] as? [String: Any] ?? [:]
    return (result["isError"] as? Bool == true, failure["message"] as? String ?? "", failure, content.count)
}

private func describe(_ value: Any?) -> String {
    value.map { String(describing: $0) } ?? "nil"
}

private struct OtherError: Error, CustomStringConvertible {
    var description: String { "screencapture went away" }
}

@main
private enum FailureTests {
    static func main() {
        // Every code with what it says about delivery and retrying. Changing one changes what agents do.
        let expected: [(FailureKind, String, Any, String)] = [
            (.invalidArgs, "INVALID_ARGS", false, "fix"), (.appNotFound, "APP_NOT_FOUND", false, "fix"),
            (.appAmbiguous, "APP_AMBIGUOUS", false, "fix"), (.unsupported, "ACTION_UNSUPPORTED", false, "fix"),
            (.permissionDenied, "PERMISSION_DENIED", false, "user"), (.screenLocked, "SCREEN_LOCKED", false, "user"),
            (.setup, "SETUP_PROBLEM", false, "user"), (.clipboardUnsafe, "CLIPBOARD_UNSAFE", false, "user"),
            (.staleScreenshot, "STALE_SCREENSHOT", false, "refresh"), (.staleRef, "STALE_REF", false, "refresh"),
            (.focusLost, "FOCUS_LOST", false, "safe"), (.appUnresponsive, "APP_UNRESPONSIVE", false, "safe"),
            (.busy, "BUSY", false, "safe"), (.internalError, "INTERNAL", false, "safe"), (.timeout, "TIMEOUT", false, "safe"),
            (.outcomeUnknown, "OUTCOME_UNKNOWN", "unknown", "check"),
        ]
        for (kind, code, delivered, retry) in expected {
            let error = parts(ToolFailure("message", kind)).error
            let deliveredMatches = (error["delivered"] as? String).map { $0 == delivered as? String }
                ?? ((error["delivered"] as? Bool).map { $0 == delivered as? Bool } ?? false)
            check("\(code): delivered \(delivered), retry \(retry)",
                  error["code"] as? String == code && deliveredMatches && error["retry"] as? String == retry,
                  "got \(error)")
        }

        let accepted = parts(ToolFailure("The app accepted it but shows no change.", .outcomeUnknown, delivered: true))
        check("an accepted action says delivered true", accepted.error["delivered"] as? Bool == true, "got \(describe(accepted.error["delivered"]))")
        check("an accepted action still asks to check", accepted.error["code"] as? String == "OUTCOME_UNKNOWN" && accepted.error["retry"] as? String == "check")
        check("the message is in the error JSON", accepted.isError && accepted.message == "The app accepted it but shows no change.")
        check("the result is one JSON part, as for a success", accepted.partCount == 1)

        let refused = parts(ToolFailure("Nothing was sent.", .outcomeUnknown, delivered: false))
        check("a known undelivered failure says delivered false", refused.error["delivered"] as? Bool == false, "got \(describe(refused.error["delivered"]))")

        let other = parts(OtherError())
        check("another error is treated as an unknown outcome",
              other.error["code"] as? String == "OUTCOME_UNKNOWN" && other.error["delivered"] as? String == "unknown"
                && other.error["retry"] as? String == "check", "got \(other.error)")
        check("another error keeps its message", other.message == "screencapture went away")

        var detailed = ToolFailure("A dialog opened.", .outcomeUnknown, delivered: true)
        detailed.details = ["opened": [["kind": "dialog"]], "code": "INVALID_ARGS", "delivered": false, "retry": "safe", "message": "replaced"]
        let withDetails = parts(detailed).error
        check("details are added", (withDetails["opened"] as? [[String: Any]])?.first?["kind"] as? String == "dialog")
        check("details cannot replace code, delivered, retry, or message",
              withDetails["code"] as? String == "OUTCOME_UNKNOWN" && withDetails["delivered"] as? Bool == true
                && withDetails["retry"] as? String == "check" && withDetails["message"] as? String == "A dialog opened.", "got \(withDetails)")
        check("slashes are not escaped", jsonString(["path": "a/b"]) == #"{"path":"a/b"}"#)

        var unusual = ToolFailure("The window moved.", .outcomeUnknown, delivered: true)
        unusual.details = ["when": Date(timeIntervalSince1970: 0), "scale": Double.nan, "nested": [["at": Date(timeIntervalSince1970: 0)]]]
        let written = parts(unusual).error
        check("values JSON cannot hold keep the error",
              written["code"] as? String == "OUTCOME_UNKNOWN" && written["delivered"] as? Bool == true, "got \(written)")
        check("and are written as text", written["when"] is String && written["scale"] as? String == "nan"
              && (written["nested"] as? [[String: Any]])?.first?["at"] is String, "got \(written)")
        let missing: String? = nil
        let present: String? = "x"
        check("optionals are written as null or their value",
              jsonString(["missing": missing as Any, "present": present as Any, "date": Date?.none as Any]) == #"{"date":null,"missing":null,"present":"x"}"#,
              jsonString(["missing": missing as Any, "present": present as Any]))
        check("keys that are not text are written as text", jsonString(["byIndex": [1: "a", 2: Date?.none as Any]]) == #"{"byIndex":{"1":"a","2":null}}"#,
              jsonString(["byIndex": [1: "a", 2: Date?.none as Any]]))
        check("JSON that is fine is left alone", jsonString(["a": 1, "b": [true, "x"]]) == #"{"a":1,"b":[true,"x"]}"#)

        if failures > 0 {
            print("\(failures) failure test(s) failed")
            exit(1)
        }
        print("All failure tests passed")
    }
}
