extends GSPlatformIdentity

const FcAvatars := preload("fc_avatars.gd")

## Who a player is: content delivery, a profile, an avatar, and one admission flow.
##
## [b]The chain is dot-platform's [GSPlatformIdentity], and this is only what is Fatal Contact's
## about it[/b]: the schema a capsule is dressed from, and the stock avatar a guest gets.
## This file was 262 lines before the layer was extracted, and game-airdrift's was 215 —
## the same chain with the class names changed.
##
## [codeblock]
## var identity := FcIdentity.new()
## add_child(identity)
## await identity.setup()
## # By PATH: GSModuleHost constructs the module itself, and finds the hub this
## # registered. platform_module() is for a host that adds the node by hand.
## await server.modules.load_module("res://addons/dot_platform/dot_platform_module.gd")
## [/codeblock]


func _init() -> void:
	avatar_schema = FcAvatars.schema()
	stock_avatar_fn = FcAvatars.stock_avatar
	avatar_translate_fn = FcAvatars.from_site
