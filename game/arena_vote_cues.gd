extends RefCounted

## The map vote's sound cues, as ids in [code]ArenaPresentation.sound_catalogue()[/code]. One
## copy: the vote's rules name them (through [code]ArenaVote.CUE_*[/code]) and the catalogue
## defines them, both from here.
##
## [b]A file of its own so a client does not compile the vote.[/b] The presentation needs these
## four ids; preloading `arena_vote.gd` for them compiled the vote, dot-vote and the map director
## (25 scripts, about 11 MB of MEMORY_STATIC) into every client, and only a server runs a vote.

const CUE_START := &"vote_start"
const CUE_END := &"vote_end"
const CUE_WARNING := &"vote_warning"
const CUE_COUNT := &"vote_count"
