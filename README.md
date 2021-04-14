# flac2mp3.pl
Perl script to transcode flac into mp3, while keeping the tags. Because hundreds of these scripts aren't enough apparently.

Dependencies: `flac` `metaflac` `lame`

# Usage
```bash
flac2mp3.pl ~/flacs ~/mp3
```

Tags can be overridden with options. Only the genre tag is supported rith now.
```bash
flac2mp3.pl --genre 145 ~/flacs ~/mp3
```
This would add the genre as 'Anime'. Run `lame --genre-list` for the whole list. Can be specified multiple ones, with comma separation (i think).
