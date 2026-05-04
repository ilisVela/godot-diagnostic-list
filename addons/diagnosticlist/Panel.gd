@tool
extends Control
class_name DiagnosticList_Panel

class DiagnosticSeveritySettings extends RefCounted:
    var text: String
    var icon: Texture2D
    var color: Color

    func _init(text_: String, icon_id: StringName, color_id: StringName) -> void:
        self.text = text_
        self.icon = EditorInterface.get_editor_theme().get_icon(icon_id, &"EditorIcons")
        self.color = EditorInterface.get_editor_theme().get_color(color_id, &"Editor")


@onready var _btn_refresh_errors: Button = %"btn_refresh_errors"
@onready var _btn_copy_all: Button = %"btn_copy_all"
@onready var _btn_copy_selected: Button = %"btn_copy_selected"
@onready var _search_text: LineEdit = %"search_text"
@onready var _error_list_tree: Tree = %"error_tree_list"
@onready var _cb_auto_refresh: CheckBox = %"cb_auto_refresh"
@onready var _cb_group_by_file: CheckBox = %"cb_group_by_file"
@onready var _label_refresh_time: Label = %"label_refresh_time"
@onready var _multiple_instances_alert: AcceptDialog = %"multiple_instances_alert"

# This array will be filled according to each severity type to allow direct indexing
@onready var _filter_buttons: Array[Button] = [
    %"btn_filter_errors",
    %"btn_filter_warnings",
    %"btn_filter_infos",
    %"btn_filter_hints",
]

# This array will be filled according to each severity type to allow direct indexing
@onready var _severity_settings: Array[DiagnosticSeveritySettings] = [
    DiagnosticSeveritySettings.new("Error", &"StatusError", &"error_color"),
    DiagnosticSeveritySettings.new("Warning", &"StatusWarning", &"warning_color"),
    DiagnosticSeveritySettings.new("Info", &"Popup", &"font_color"),
    DiagnosticSeveritySettings.new("Hint", &"Info", &"font_color"),
]

@onready var _script_icon: Texture2D = get_theme_icon(&"Script", &"EditorIcons")

var _provider: DiagnosticList_DiagnosticProvider
var _last_selected_item: TreeItem = null


## Alternative to _ready(). This will be called by plugin.gd to ensure the code in here only runs
## when this script is loaded as part of the plugin and not while editing the scene.
func _plugin_ready() -> void:
    DiagnosticList_Utils.log_debug("Panel _plugin_ready()")

    for i in len(_filter_buttons):
        var btn: Button = _filter_buttons[i]
        var severity := _severity_settings[i]
        btn.icon = severity.icon

    # These kinds of severities do not exist yet in Godot LSP, so hide them for now.
    _filter_buttons[DiagnosticList_Diagnostic.Severity.Info].hide()
    _filter_buttons[DiagnosticList_Diagnostic.Severity.Hint].hide()

    _cb_auto_refresh.button_pressed = DiagnosticList_Settings.get_auto_refresh()
    _search_text.right_icon = get_theme_icon(&"Search", &"EditorIcons")

    _error_list_tree.columns = 3
    _error_list_tree.set_column_title(0, "Message")
    _error_list_tree.set_column_title(1, "File")
    _error_list_tree.set_column_title(2, "Line")
    _error_list_tree.set_column_title_alignment(0, HORIZONTAL_ALIGNMENT_LEFT)
    _error_list_tree.set_column_title_alignment(1, HORIZONTAL_ALIGNMENT_LEFT)
    _error_list_tree.set_column_title_alignment(2, HORIZONTAL_ALIGNMENT_LEFT)

    var line_column_size := _error_list_tree.get_theme_font("font").get_string_size(
        "Line 0000", HORIZONTAL_ALIGNMENT_LEFT, -1, _error_list_tree.get_theme_font_size("font_size"))

    _error_list_tree.set_column_custom_minimum_width(0, 0)
    _error_list_tree.set_column_custom_minimum_width(1, 0)
    _error_list_tree.set_column_custom_minimum_width(2, int(line_column_size.x))

    _error_list_tree.set_column_expand(0, true)
    _error_list_tree.set_column_expand(1, true)
    _error_list_tree.set_column_expand(2, false)
    _error_list_tree.set_column_clip_content(0, true)
    _error_list_tree.set_column_clip_content(1, true)
    _error_list_tree.set_column_clip_content(2, false)
    _error_list_tree.set_column_expand_ratio(0, 4)
    _error_list_tree.select_mode = Tree.SELECT_MULTI
    _error_list_tree.gui_input.connect(_on_tree_gui_input)

    _multiple_instances_alert.add_button("More Information", true, "https://github.com/mphe/godot-diagnostic-list#does-not-work-correctly-with-multiple-godot-instances")
    _multiple_instances_alert.custom_action.connect(func(action: StringName) -> void: OS.shell_open(action))
    _multiple_instances_alert.visible = false


## Called by plugin.gd when the LSPClient is ready
func start(provider: DiagnosticList_DiagnosticProvider) -> void:
    DiagnosticList_Utils.log_debug("Panel start()")

    _provider = provider

    # Now that it is safe to do stuff, connect all the signals
    _provider.on_diagnostics_finished.connect(_on_diagnostics_finished)
    _provider.on_update_progress.connect(_on_update_progress)

    _btn_refresh_errors.pressed.connect(_on_force_refresh)
    _btn_copy_all.pressed.connect(_on_copy_all)
    _btn_copy_selected.pressed.connect(_on_copy_selected)
    _search_text.text_changed.connect(_on_search_text_changed)
    _cb_group_by_file.toggled.connect(_on_group_by_file_toggled)
    _cb_auto_refresh.toggled.connect(_on_auto_refresh_toggled)
    _error_list_tree.item_activated.connect(_on_item_activated)

    for btn in _filter_buttons:
        btn.toggled.connect(_on_filter_toggled)

    # Start checking
    _set_status_string("", false)
    DiagnosticList_Utils.log_debug("Panel start(): auto_refresh=%s group_by_file=%s" % [str(_cb_auto_refresh.button_pressed), str(_cb_group_by_file.button_pressed)])
    _start_stop_auto_refresh()

    # Multi-instance warning disabled: current queue/batching implementation is stable in this setup.


func refresh() -> void:
    DiagnosticList_Utils.log_debug("Panel refresh()")

    # NOTE: This list is grouped by file name. This is important as the group-by-file implementation relies on it.
    var diagnostics := _get_filtered_diagnostics()
    var group_by_file := _cb_group_by_file.button_pressed

    if not group_by_file:
        diagnostics.sort_custom(DiagnosticList_Utils.sort_by_severity)

    # Show refresh time
    _set_status_string("Up-to-date", true)

    # Clear tree
    _error_list_tree.clear()
    _error_list_tree.create_item()

    # Create diagnostics
    var last_uri: StringName
    var parent: TreeItem = null

    for diag in diagnostics:
        # If grouping by file, create header entries if necessary
        if group_by_file and diag.res_uri != last_uri:
            last_uri = diag.res_uri
            parent = _error_list_tree.create_item()
            parent.set_text(0, diag.res_uri)
            parent.set_icon(0, _script_icon)
            parent.set_metadata(0, diag)

        _create_entry(diag, parent)

    # Update diagnostic counts
    for i in len(_filter_buttons):
        _filter_buttons[i].text = str(_provider.get_diagnostic_count(i))


func _set_status_string(text: String, with_last_time: bool) -> void:
    if with_last_time:
        _label_refresh_time.text = "%s\n%.2f s" % [ text, _provider.get_refresh_time_usec() / 1000000.0 ]
    else:
        _label_refresh_time.text = text


func _create_entry(diag: DiagnosticList_Diagnostic, parent: TreeItem) -> void:
    var entry: TreeItem = _error_list_tree.create_item(parent)
    var severity_setting := _severity_settings[diag.severity]
    # entry.set_custom_color(0, theme.color)
    entry.set_text(0, diag.message)
    entry.set_icon(0, severity_setting.icon)
    entry.set_text(1, diag.get_filename())
    entry.set_tooltip_text(1, diag.res_uri)
    # entry.set_text(2, "Line " + str(diag.line_start))
    entry.set_text(2, str(diag.line_start + 1))
    entry.set_metadata(0, diag)  # Meta data is used in _on_item_activated to open the respective script


func _update_diagnostics(force: bool) -> void:
    DiagnosticList_Utils.log_debug("Panel _update_diagnostics(force=%s) visible=%s provider_updating=%s" % [str(force), str(is_visible_in_tree()), str(_provider.is_updating())])

    if _provider.is_updating() or _provider.refresh_diagnostics(force):
        _set_status_string("Updating...", false)
    else:
        _set_status_string("Up-to-date", true)


func _start_stop_auto_refresh() -> void:
    if _cb_auto_refresh.button_pressed:
        visibility_changed.connect(_on_auto_update)
        _provider.on_diagnostics_available.connect(_on_auto_update)
        _on_auto_update()  # Also trigger an update immediately
    else:
        visibility_changed.disconnect(_on_auto_update)
        _provider.on_diagnostics_available.disconnect(_on_auto_update)


func _on_item_activated() -> void:
    var selected: TreeItem = _error_list_tree.get_selected()
    var diagnostic: DiagnosticList_Diagnostic = selected.get_metadata(0)

    # NOTE: Lines and columns are zero-based in LSP, but Godot expects one-based values
    EditorInterface.edit_script(load(str(diagnostic.res_uri)), diagnostic.line_start + 1, diagnostic.column_start + 1)

    if not EditorInterface.get_editor_settings().get("text_editor/external/use_external_editor"):
        EditorInterface.set_main_screen_editor("Script")


func _on_force_refresh() -> void:
    _update_diagnostics(true)


func _on_auto_refresh_toggled(toggled_on: bool) -> void:
    DiagnosticList_Settings.set_auto_refresh(toggled_on)
    _start_stop_auto_refresh()


func _on_auto_update() -> void:
    if is_visible_in_tree():
        _update_diagnostics(false)


func _on_update_progress(num_remaining: int, num_all: int) -> void:
    _set_status_string("Updating...\n(%d/%d)" % [ num_all - num_remaining, num_all ], false)


func _on_diagnostics_finished() -> void:
    refresh()

func _on_filter_toggled(_toggled_on: bool) -> void:
    refresh()

func _on_group_by_file_toggled(_toggled_on: bool) -> void:
    refresh()


func _on_copy_all() -> void:
    var diagnostics := _get_filtered_diagnostics()
    if diagnostics.is_empty():
        _set_status_string("Nothing to copy", false)
        return

    var text := DiagnosticList_Utils.diagnostics_to_string(
        diagnostics,
        _get_enabled_severities(),
        _get_severity_labels()
    )

    if text.is_empty():
        _set_status_string("Nothing to copy", false)
        return

    DisplayServer.clipboard_set(text)
    var count := text.count("\n") + 1
    _set_status_string("Copied %d item(s)" % count, false)


func _on_copy_selected() -> void:
    var selected_item := _error_list_tree.get_next_selected(null)
    if selected_item == null:
        _set_status_string("Nothing selected", false)
        return

    var selected_diags: Array[DiagnosticList_Diagnostic] = []
    var count := 0
    while selected_item != null:
        var diag: DiagnosticList_Diagnostic = selected_item.get_metadata(0)
        if diag != null:
            selected_diags.append(diag)
            count += 1
        selected_item = _error_list_tree.get_next_selected(selected_item)

    var text := DiagnosticList_Utils.diagnostics_to_string(
        selected_diags,
        _get_enabled_severities(),
        _get_severity_labels()
    )

    if text.is_empty():
        _set_status_string("Nothing to copy", false)
        return

    DisplayServer.clipboard_set(text)
    _set_status_string("Copied %d item(s)" % count, false)


func _get_enabled_severities() -> Array[bool]:
    var enabled: Array[bool] = []
    for btn in _filter_buttons:
        enabled.append(btn.button_pressed)
    return enabled


func _get_severity_labels() -> Array[String]:
    var labels: Array[String] = []
    for severity in _severity_settings:
        labels.append(severity.text)
    return labels


func _on_tree_gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        var clicked_item := _error_list_tree.get_item_at_position(event.position)
        if clicked_item == null:
            return

        if event.shift_pressed and _last_selected_item != null:
            # Shift-click: select range
            _select_range(_last_selected_item, clicked_item)
            # Consume the event so Tree doesn't deselect
            _error_list_tree.accept_event()
        else:
            # Normal click: update last selected
            _last_selected_item = clicked_item


func _select_range(from_item: TreeItem, to_item: TreeItem) -> void:
    # Get all items in a flat list
    var all_items: Array[TreeItem] = []
    _collect_tree_items(_error_list_tree.get_root(), all_items)

    # Find indices
    var from_idx := all_items.find(from_item)
    var to_idx := all_items.find(to_item)

    if from_idx == -1 or to_idx == -1:
        return

    # Ensure from < to
    if from_idx > to_idx:
        var tmp := from_idx
        from_idx = to_idx
        to_idx = tmp

    # Select range
    for i in range(from_idx, to_idx + 1):
        all_items[i].select(0)


func _collect_tree_items(item: TreeItem, result: Array[TreeItem]) -> void:
    if item == null:
        return

    # Skip root
    if item != _error_list_tree.get_root():
        result.append(item)

    # Process children
    for child in item.get_children():
        _collect_tree_items(child, result)


func _on_search_text_changed(_new_text: String) -> void:
    refresh()


func _get_filtered_diagnostics() -> Array[DiagnosticList_Diagnostic]:
    var all_diagnostics := _provider.get_diagnostics()
    var filtered: Array[DiagnosticList_Diagnostic] = []
    var query := _search_text.text.strip_edges().to_lower()
    var has_query := not query.is_empty()

    for diag in all_diagnostics:
        if not _filter_buttons[diag.severity].button_pressed:
            continue
        if has_query and not _diagnostic_matches_query(diag, query):
            continue
        filtered.append(diag)
    return filtered


func _diagnostic_matches_query(diag: DiagnosticList_Diagnostic, query: String) -> bool:
    return (
        diag.message.to_lower().contains(query)
        or diag.get_filename().to_lower().contains(query)
        or str(diag.res_uri).to_lower().contains(query)
    )
