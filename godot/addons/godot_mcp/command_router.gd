@tool
extends RefCounted
class_name MCPCommandRouter

var _commands: Dictionary = {}
var _handlers: Array[MCPBaseCommand] = []
var _extensions: Dictionary = {}
var _extension_owners: Dictionary = {}
const EXTENSION_SETTING := "godot_mcp/extensions"



func setup(plugin: EditorPlugin) -> void:
	_register_handler(MCPSystemCommands.new(), plugin)
	_register_handler(MCPSceneCommands.new(), plugin)
	_register_handler(MCPNodeCommands.new(), plugin)
	_register_handler(MCPSelectionCommands.new(), plugin)
	_register_handler(MCPProjectCommands.new(), plugin)
	_register_handler(MCPDebugCommands.new(), plugin)
	_register_handler(MCPScreenshotCommands.new(), plugin)
	_register_handler(MCPAnimationCommands.new(), plugin)
	_register_handler(MCPTilemapCommands.new(), plugin)
	_register_handler(MCPResourceCommands.new(), plugin)
	_register_handler(MCPScene3DCommands.new(), plugin)
	_register_handler(MCPInputCommands.new(), plugin)
	_register_handler(MCPProfilerCommands.new(), plugin)
	_register_handler(MCPRuntimeStateCommands.new(), plugin)
	_register_handler(MCPGameTimeCommands.new(), plugin)
	_register_handler(MCPExecCommands.new(), plugin)
	_register_handler(MCPMeshCommands.new(), plugin)
	_commands["list_extension_tools"] = _list_extension_tools
	var paths: PackedStringArray = ProjectSettings.get_setting(EXTENSION_SETTING, PackedStringArray())
	for path in paths:
		if not path.begins_with("res://") or not ResourceLoader.exists(path):
			MCPLog.warn("MCP extension script unavailable: %s" % path)
			continue
		var script := load(path) as Script
		if script == null or not script.can_instantiate():
			MCPLog.warn("MCP extension script invalid: %s" % path)
			continue
		var provider = script.new()
		if not provider is RefCounted or not provider.has_method("setup") or not provider.has_method("get_extension_id") or not provider.has_method("get_tools"):
			MCPLog.warn("MCP extension contract invalid: %s" % path)
			continue
		register_extension(provider, plugin)



func _register_handler(handler: MCPBaseCommand, plugin: EditorPlugin) -> void:
	handler.setup(plugin)
	_handlers.append(handler)
	var cmds := handler.get_commands()
	for cmd_name in cmds:
		_commands[cmd_name] = cmds[cmd_name]

func register_extension(provider: RefCounted, plugin: EditorPlugin) -> bool:
	provider.call("setup", plugin)
	var id: String = provider.call("get_extension_id")
	if id.is_empty() or _extensions.has(id):
		MCPLog.warn("Duplicate or empty MCP extension id: %s" % id)
		_shutdown_provider(provider)
		return false
	var tools: Dictionary = provider.call("get_tools")
	# Validate the entire batch before publishing any command.
	for name in tools:
		var definition = tools[name]
		if not name is String or not name.begins_with("godot_") or _commands.has(name) or not definition is Dictionary:
			MCPLog.warn("Invalid or conflicting MCP extension tool: %s" % str(name))
			_shutdown_provider(provider)
			return false
		if not definition.get("description") is String or not definition.get("inputSchema") is Dictionary or not definition.get("handler") is Callable or not definition["handler"].is_valid():
			MCPLog.warn("Invalid MCP extension tool definition: %s" % name)
			_shutdown_provider(provider)
			return false
	_extensions[id] = {"provider": provider, "tools": tools}
	for name in tools:
		_commands[name] = tools[name]["handler"]
		_extension_owners[name] = id
	return true


func unregister_extension(id: String) -> void:
	if not _extensions.has(id):
		return
	var entry: Dictionary = _extensions[id]
	for name in entry["tools"]:
		_commands.erase(name)
		_extension_owners.erase(name)
	var provider: RefCounted = entry["provider"]
	_shutdown_provider(provider)
	_extensions.erase(id)

func _shutdown_provider(provider: RefCounted) -> void:
	if provider.has_method("shutdown"):
		provider.call("shutdown")


func shutdown() -> void:
	for id in _extensions.keys():
		unregister_extension(id)


func _list_extension_tools(_params: Dictionary) -> Dictionary:
	var tools: Array = []
	for entry in _extensions.values():
		for name in entry["tools"]:
			var definition: Dictionary = entry["tools"][name]
			tools.append({
				"name": name,
				"description": definition["description"],
				"inputSchema": definition["inputSchema"]
			})
	return MCPUtils.success({"tools": tools})


func handle_command(command: String, params: Dictionary):
	if not _commands.has(command):
		return MCPUtils.error("UNKNOWN_COMMAND", "Unknown command: %s" % command)

	var is_extension: bool = _extension_owners.has(command)
	var callable: Callable = _commands[command]
	var result = await callable.call(params)
	if is_extension:
		if not result is Dictionary:
			return MCPUtils.error("EXTENSION_ERROR", "Extension tool returned a non-object result: %s" % command)
		if result.has("error") and result["error"] is String:
			return MCPUtils.error("EXTENSION_ERROR", result["error"])
		return MCPUtils.success(result)
	return result
