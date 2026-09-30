{ lib, python3Packages, fetchPypi }:

python3Packages.buildPythonApplication rec {
  pname = "python-ember-mug";
  version = "1.3.3";
  pyproject = true;

  src = fetchPypi {
    pname = "python_ember_mug";
    inherit version;
    hash = "sha256-IVhYMcyDXGYKdAUhmsnhe0qqjAaaNoNog856M/rQL+s=";
  };

  postPatch = ''
    # `ember-mug set` never unlocks the mug's BLE write-lock before writing
    # attributes (upstream: sopelj/python-ember-mug#88). Cosmetic writes
    # (name, LED colour) go through unlocked, but the mug firmware rejects
    # the target-temperature write and drops the connection. The library
    # already ships make_writable() (writes a throwaway UDSK to unlock) —
    # the CLI's set command just never calls it before writing.
    substituteInPlace ember_mug/cli/commands.py \
      --replace-fail $'        for attr, value in values:' \
                      $'        await mug.make_writable()\n        for attr, value in values:'

    # set_temperature_unit() compares the CLI's bare "C"/"F" against
    # TemperatureUnit.FAHRENHEIT, whose real value is "°F" — always False,
    # so it silently writes Celsius to the mug no matter which unit was
    # requested, then crashes building TemperatureUnit("F") since only
    # "°C"/"°F" are valid enum values. Normalize the bare letter first.
    substituteInPlace ember_mug/mug.py \
      --replace-fail $'        text_unit = unit.value if isinstance(unit, StrEnum) else unit' \
                      $'        if isinstance(unit, str) and unit.upper() in ("C", "F"):\n            unit = TemperatureUnit.FAHRENHEIT if unit.upper() == "F" else TemperatureUnit.CELSIUS\n        text_unit = unit.value if isinstance(unit, StrEnum) else unit'

    # find_device() locates the mug purely by listening for its BLE
    # advertisement broadcasts (scanner.advertisement_data()) -- but a mug
    # already connected via BlueZ (the common case: BlueZ auto-reconnects
    # bonded/trusted devices whenever they're in range) stops advertising,
    # so the scan can never find it. Every call against an already-connected
    # mug burns the full 30s timeout and fails with "No device was found"
    # even though the device is fully reachable (confirmed live: connected
    # -> always fails in ~30s; same mug disconnected -> succeeds in ~10s).
    # bleak-retry-connector (already a dependency, see below) ships
    # get_device(), which fetches a BlueZ-known device directly over D-Bus
    # -- connected or not -- with no scan required. Try that first; only
    # fall back to the scan if it comes back empty (device never
    # paired/seen by this adapter at all).
    #
    # BlueZ keeps the device's last-seen Name/ManufacturerData/UUIDs as
    # persistent D-Bus properties even while not currently advertising
    # (confirmed live: a bonded, currently-connected mug's cached
    # ManufacturerData still decodes to the real model via
    # get_model_info_from_advertiser_data) -- read those into the
    # synthesized AdvertisementData instead of leaving it empty. An empty
    # manufacturer_data makes model detection fall back to UNKNOWN_DEVICE,
    # which device_attributes() then treats as a Cup/Tumbler and silently
    # drops "name" from the readable attribute set -- `ember-mug get -r
    # name` would raise NotImplementedError even though the connection
    # itself succeeded.
    substituteInPlace ember_mug/scanner.py \
      --replace-fail $'from bleak import BleakScanner' \
                      $'from bleak import AdvertisementData, BleakScanner\nfrom bleak_retry_connector import get_device as get_known_device' \
      --replace-fail $'    if mac is not None:\n        mac = mac.lower()\n    async with BleakScanner(**build_scanner_kwargs(adapter)) as scanner:' \
                      $'    if mac is not None:\n        mac = mac.lower()\n        if known_device := await get_known_device(mac):\n            props = known_device.details.get("props", {}) if isinstance(known_device.details, dict) else {}\n            return known_device, AdvertisementData(\n                local_name=props.get("Name") or known_device.name,\n                manufacturer_data=props.get("ManufacturerData") or {},\n                service_data={},\n                service_uuids=props.get("UUIDs") or [],\n                tx_power=None,\n                rssi=getattr(known_device, "rssi", None) or -127,\n                platform_data=(),\n            )\n    async with BleakScanner(**build_scanner_kwargs(adapter)) as scanner:'

    # Knock-on effect of the find_device() patch above: once a poll can
    # actually reuse an already-BlueZ-connected mug, `disconnect()`'s
    # `await self._client.disconnect()` (D-Bus Disconnect() call, awaiting
    # BlueZ's reply) intermittently raises EOFError deep in dbus_fast's
    # message unmarshaller (confirmed live) -- the read of every requested
    # attribute already completed successfully by this point (`get_*`
    # happens entirely before disconnect in commands.py's
    # get_device_value_cmd), so this is purely a cleanup-time failure, not
    # a data-loss one. But `get_device_value_cmd` only prints results
    # *after* `async with mug.connection()` exits, so an uncaught exception
    # here discards an otherwise-successful read and crashes the CLI with a
    # nonzero exit. Disconnecting is best-effort: BlueZ's own connection
    # state isn't affected by our client-side disconnect failing, so log
    # and move on instead of propagating.
    substituteInPlace ember_mug/mug.py \
      --replace-fail $'        if self._client and self._client.is_connected:\n            async with self._connect_lock:\n                await self.unsubscribe()\n                await self._client.disconnect()' \
                      $'        if self._client and self._client.is_connected:\n            async with self._connect_lock:\n                try:\n                    await self.unsubscribe()\n                    await self._client.disconnect()\n                except Exception:\n                    logger.debug("Ignoring error while disconnecting", exc_info=True)'
  '';

  build-system = with python3Packages; [ hatchling ];

  dependencies = with python3Packages; [
    bleak
    bleak-retry-connector
  ];

  pythonImportsCheck = [ "ember_mug" ];

  meta = {
    description = "CLI and library for controlling Ember smart mugs over Bluetooth";
    homepage = "https://github.com/sopelj/python-ember-mug";
    license = lib.licenses.mit;
    mainProgram = "ember-mug";
    platforms = lib.platforms.linux;
  };
}
