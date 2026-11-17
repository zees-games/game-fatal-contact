extends RefCounted

## The map vote's sound cue ids in [code]FcPresentation.sound_catalogue()[/code], one copy for
## the vote ([code]FcVote.CUE_*[/code]) and the catalogue. Its own file so a client does not
## compile the vote (25 scripts, ~11 MB); only a server runs a vote.

const CUE_START := &"vote_start"
const CUE_END := &"vote_end"
const CUE_WARNING := &"vote_warning"
const CUE_COUNT := &"vote_count"
