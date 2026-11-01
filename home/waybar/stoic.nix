{ config, pkgs, lib, ... }:

let
  cacheName = "stoic-quote";

  # Offline on purpose: the stoic-quotes.com API went dark (Vercel
  # DEPLOYMENT_DISABLED), so a bundled list can't die the same way.
  quotes = [
    { text = "You have power over your mind, not outside events. Realize this, and you will find strength."; author = "Marcus Aurelius"; }
    { text = "The happiness of your life depends upon the quality of your thoughts."; author = "Marcus Aurelius"; }
    { text = "If it is not right, do not do it; if it is not true, do not say it."; author = "Marcus Aurelius"; }
    { text = "The impediment to action advances action. What stands in the way becomes the way."; author = "Marcus Aurelius"; }
    { text = "Waste no more time arguing about what a good man should be. Be one."; author = "Marcus Aurelius"; }
    { text = "Very little is needed to make a happy life; it is all within yourself, in your way of thinking."; author = "Marcus Aurelius"; }
    { text = "When you arise in the morning, think of what a precious privilege it is to be alive: to breathe, to think, to enjoy, to love."; author = "Marcus Aurelius"; }
    { text = "Dwell on the beauty of life. Watch the stars, and see yourself running with them."; author = "Marcus Aurelius"; }
    { text = "Look well into thyself; there is a source of strength which will always spring up if thou wilt always look."; author = "Marcus Aurelius"; }
    { text = "Accept the things to which fate binds you, and love the people with whom fate brings you together, but do so with all your heart."; author = "Marcus Aurelius"; }
    { text = "Everything we hear is an opinion, not a fact. Everything we see is a perspective, not the truth."; author = "Marcus Aurelius"; }
    { text = "The best revenge is not to be like your enemy."; author = "Marcus Aurelius"; }
    { text = "It is not death that a man should fear, but he should fear never beginning to live."; author = "Marcus Aurelius"; }
    { text = "Today I escaped anxiety. Or no, I discarded it, because it was within me, in my own perceptions, not outside."; author = "Marcus Aurelius"; }
    { text = "Death smiles at us all; all a man can do is smile back."; author = "Marcus Aurelius"; }
    { text = "We suffer more often in imagination than in reality."; author = "Seneca"; }
    { text = "Luck is what happens when preparation meets opportunity."; author = "Seneca"; }
    { text = "It is not that we have a short time to live, but that we waste much of it."; author = "Seneca"; }
    { text = "While we are postponing, life speeds by."; author = "Seneca"; }
    { text = "Difficulties strengthen the mind, as labor does the body."; author = "Seneca"; }
    { text = "He who is brave is free."; author = "Seneca"; }
    { text = "No man is more unhappy than he who never faces adversity. For he is not permitted to prove himself."; author = "Seneca"; }
    { text = "Begin at once to live, and count each separate day as a separate life."; author = "Seneca"; }
    { text = "True happiness is to enjoy the present, without anxious dependence upon the future."; author = "Seneca"; }
    { text = "Sometimes even to live is an act of courage."; author = "Seneca"; }
    { text = "As is a tale, so is life: not how long it is, but how good it is, is what matters."; author = "Seneca"; }
    { text = "If a man knows not to which port he sails, no wind is favorable."; author = "Seneca"; }
    { text = "Associate with people who are likely to improve you."; author = "Seneca"; }
    { text = "Hang on to your youthful enthusiasms; you will be able to use them to better effect when you are older."; author = "Seneca"; }
    { text = "The whole future lies in uncertainty: live immediately."; author = "Seneca"; }
    { text = "Fate leads the willing, and drags along the reluctant."; author = "Seneca"; }
    { text = "It's not what happens to you, but how you react to it that matters."; author = "Epictetus"; }
    { text = "Men are disturbed not by things, but by the views which they take of them."; author = "Epictetus"; }
    { text = "First say to yourself what you would be; and then do what you have to do."; author = "Epictetus"; }
    { text = "No man is free who is not master of himself."; author = "Epictetus"; }
    { text = "Wealth consists not in having great possessions, but in having few wants."; author = "Epictetus"; }
    { text = "He is a wise man who does not grieve for the things which he has not, but rejoices for those which he has."; author = "Epictetus"; }
    { text = "Make the best use of what is in your power, and take the rest as it happens."; author = "Epictetus"; }
    { text = "If you want to improve, be content to be thought foolish and stupid."; author = "Epictetus"; }
    { text = "It is impossible for a man to learn what he thinks he already knows."; author = "Epictetus"; }
    { text = "Don't explain your philosophy. Embody it."; author = "Epictetus"; }
    { text = "Any person capable of angering you becomes your master."; author = "Epictetus"; }
    { text = "We have two ears and one mouth so that we can listen twice as much as we speak."; author = "Epictetus"; }
    { text = "Circumstances don't make the man, they only reveal him to himself."; author = "Epictetus"; }
    { text = "Only the educated are free."; author = "Epictetus"; }
    { text = "Seek not that the things which happen should happen as you wish; but wish the things which happen to be as they are, and you will have a tranquil flow of life."; author = "Epictetus"; }
    { text = "He who laughs at himself never runs out of things to laugh at."; author = "Epictetus"; }
    { text = "Some things are in our control and others not."; author = "Epictetus"; }
    { text = "Be not swayed by the opinions of others; they are not yours to control."; author = "Epictetus"; }
    { text = "The chief task in life is simply this: to identify and separate matters so that I can say clearly to myself which are externals not under my control, and which have to do with the choices I actually control."; author = "Epictetus"; }
    { text = "Nothing is more honorable than a grateful heart."; author = "Seneca"; }
  ];
  quotesFile = pkgs.writeText "stoic-quotes.json" (builtins.toJSON quotes);

  # Icon is emitted via jq escape sequence (U+EF0D = fa-scroll),
  # verified present in the installed Symbols Nerd Font Mono cmap via
  # fonttools/ttx against the real .ttf; rather than a literal pasted
  # glyph in this Nix file — Private Use Area characters do not reliably
  # survive being typed into source text.
  quoteScript = pkgs.writeShellScriptBin "waybar-stoic-quote" ''
    export PATH="${lib.makeBinPath [ pkgs.jq pkgs.coreutils ]}:$PATH"
    set -euo pipefail

    # One quote per hour, stepping through the list in order.
    idx=$(( $(date +%s) / 3600 ))
    jq -c --argjson i "$idx" '
      .[$i % length]
      | {text: "\uef0d", tooltip: ("\"" + .text + "\"\n— " + .author), class: "quote"}
    ' ${quotesFile}
  '';

  cacheTools = import ./cache-tools.nix { inherit pkgs; };
  cachePollScript = cacheTools.cachePoll;
  cacheReadScript = cacheTools.cacheRead;
in
{
  options.waybar.stoicQuote.enable = lib.mkEnableOption "Stoic quote module";

  # Poll-and-cache only -- the display surface is the eww ledger chip
  # (home/eww/eww.yuck's `stoic_quote` deflisten reads the same
  # ~/.cache/waybar/stoic-quote.json this poll writes), not a waybar bar
  # module.
  config = lib.mkIf config.waybar.stoicQuote.enable {
    home.packages = [ quoteScript cachePollScript cacheReadScript ];

    systemd.user.services."waybar-${cacheName}-poll" = {
      Unit = config.lib.niri.unit { wayland = true; } {
        Description = "Poll a fresh Stoic quote into cache for waybar";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${cachePollScript}/bin/waybar-cache-poll ${cacheName} ${quoteScript}/bin/waybar-stoic-quote";
      };
    };

    systemd.user.timers."waybar-${cacheName}-poll" = {
      Unit.Description = "Stoic quote poll timer";
      Timer = {
        OnStartupSec = "5s";
        OnUnitActiveSec = "60min";
        AccuracySec = "1min";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}