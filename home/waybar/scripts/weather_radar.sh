#!/usr/bin/env bash
# Opens windy.com radar centered on the saved weather location.
# Falls back to a plain radar overview if no location is configured.

LOCATION_JSON="$HOME/.config/waybar/weather_location.json"

if [ -f "$LOCATION_JSON" ]; then
    read -r lat lon < <(jq -r '
        (.USE_LOCATION) as $use |
        .SAVED_LOCATIONS[] | select(.name == $use) | "\(.lat) \(.lon)"
    ' "$LOCATION_JSON" 2>/dev/null | head -1)

    # Fallback: first entry if USE_LOCATION doesn't match
    if [ -z "$lat" ]; then
        read -r lat lon < <(jq -r '.SAVED_LOCATIONS[0] | "\(.lat) \(.lon)"' "$LOCATION_JSON" 2>/dev/null)
    fi
fi

if [ -n "$lat" ] && [ -n "$lon" ]; then
    xdg-open "https://www.windy.com/${lat}/${lon}?radar"
else
    xdg-open "https://www.windy.com/?radar"
fi
