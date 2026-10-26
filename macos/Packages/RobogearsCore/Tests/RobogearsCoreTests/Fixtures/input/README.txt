Synthetic tracklist files for the input and import parsing tests. Every song, artist, ID and URL is made up.

The column layouts are written from memory and still need checking against real files (decision cards G4-5 and G4-15 spikes):
- exportify-classic.csv: an older Exportify layout with "Artist URI(s)" before "Artist Name(s)", plus ISRC and "Track Duration (ms)".
- exportify-current.csv: a shorter Exportify layout with a byte-order mark and CRLF line endings.
- music-app-export.txt: Music's File > Library > Export Playlist text: UTF-16 LE with a byte-order mark, tab-separated, CR line endings.
- excel-semicolon-windows1252.csv: Excel on Windows in a European locale: semicolons, Windows-1252, CRLF.
- web-table-rows.txt: rows copied from a web table: number, title, artist, length, no header.
- pasted-list.txt: a pasted list with numbering, both orders, a hyphenated title, link lines and a duplicate.

The encodings are exact bytes on purpose: open them with a hex viewer, not an editor that might re-save them as UTF-8.
