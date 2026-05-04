@tool
extends RefCounted
class_name DiagnosticList_Utils


const ENABLE_DEBUG_LOG: bool = true


static func log_debug(text: String) -> void:
    if ENABLE_DEBUG_LOG:
        print("[DiagnosticList] ", text)


static func log_error(text: String) -> void:
    push_error("[DiagnosticList] ", text)


static func sort_by_severity(a: DiagnosticList_Diagnostic, b: DiagnosticList_Diagnostic) -> bool:
    if a.severity == b.severity:
        return a.res_uri < b.res_uri
    return a.severity < b.severity


static func sort_by_uri(a: DiagnosticList_Diagnostic, b: DiagnosticList_Diagnostic) -> bool:
    return a.res_uri < b.res_uri


static func diagnostics_to_string(
    diagnostics: Array[DiagnosticList_Diagnostic],
    enabled_severities: Array[bool],
    severity_labels: Array[String]
) -> String:
    var lines: Array[String] = []
    for diag in diagnostics:
        var sev: int = int(diag.severity)
        if sev < 0 or sev >= enabled_severities.size():
            continue
        if not enabled_severities[sev]:
            continue

        var sev_label: String = str(sev)
        if sev < severity_labels.size():
            sev_label = severity_labels[sev]

        lines.append("[%s] %s:%d - %s" % [
            sev_label,
            diag.get_filename(),
            diag.line_start + 1,
            diag.message,
        ])
    return "\n".join(lines)
