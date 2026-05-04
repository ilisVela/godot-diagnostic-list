@tool
extends EditorPlugin

const panel_scene = preload("res://addons/diagnosticlist/Panel.tscn")

var _dock: DiagnosticList_Panel
var _client: DiagnosticList_LSPClient
var _provider: DiagnosticList_DiagnosticProvider


func _enter_tree() -> void:
    DiagnosticList_Utils.log_debug("Plugin _enter_tree() start")
    var settings := EditorInterface.get_editor_settings()
    var lsp_enabled: bool = true
    if settings != null and settings.has_setting("network/language_server/enable"):
        lsp_enabled = bool(settings.get("network/language_server/enable"))
    if not lsp_enabled:
        DiagnosticList_Utils.log_error("Editor language server disabled; Diagnostic List plugin will stay inactive.")
        return

    # Wait a moment until the LSP server started
    await get_tree().create_timer(1.0).timeout
    DiagnosticList_Utils.log_debug("Plugin _enter_tree() post-delay")

    _client = DiagnosticList_LSPClient.new(self)
    _client.on_connected.connect(func() -> void: DiagnosticList_Utils.log_debug("Plugin received on_connected"))
    _client.on_initialized.connect(_on_lsp_initialized)
    var ok: bool = _client.connect_lsp()
    DiagnosticList_Utils.log_debug("Plugin connect_lsp() => %s" % str(ok))

    _dock = panel_scene.instantiate()
    _dock.ready.connect(func() -> void: _dock._plugin_ready())
    add_control_to_bottom_panel(_dock, "Diagnostics")

    DiagnosticList_Utils.log_debug("Plugin loaded")


func _exit_tree() -> void:
    if _dock != null:
        remove_control_from_bottom_panel(_dock)
        _dock.free()
        _dock = null
    if _client != null:
        _client.disconnect_lsp()
        _client = null
    DiagnosticList_Utils.log_debug("Plugin unloaded")


func _on_lsp_initialized() -> void:
    DiagnosticList_Utils.log_debug("Plugin _on_lsp_initialized()")
    _provider = DiagnosticList_DiagnosticProvider.new(_client)
    _provider.on_update_progress.connect(func(rem: int, total: int) -> void:
        DiagnosticList_Utils.log_debug("Provider progress %d/%d outstanding" % [rem, total])
    )
    _provider.on_diagnostics_finished.connect(func() -> void:
        DiagnosticList_Utils.log_debug("Provider diagnostics finished")
    )
    _dock.start(_provider)
