# Collection header (metadata.pegasus.txt) for one hosts/retro-systems.nix entry.
# Shared by desktop and surface so a system that matches by `regex` (rpcs3)
# works on both; `directories` is where that host's ROMs actually live.
{ pkgs }:
{ s, directories ? ".", name ? "pegasus-metadata-${s.dir}" }:
pkgs.writeText name ''
  collection: ${s.collection}
  shortname: ${s.shortname}
  ${if s ? regex then "regex: ${s.regex}" else "extensions: ${s.extensions}"}
  launch: ${s.launch}
  directories: ${directories}
''
