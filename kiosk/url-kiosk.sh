#!/usr/bin/env bash
# URL_KIOSK_DISTRIBUTION_FORMAT=1
set -euo pipefail
export URL_KIOSK_LAUNCHER="$(realpath -- "$0")"
exec /usr/bin/python3 - "$@" <<'URL_KIOSK_PYTHON'
KIOSK_VERSION = 'ec9e0c77ac1b'
import sys, types
startup = types.ModuleType("url_kiosk_bootstrap")
sys.modules[startup.__name__] = startup
exec('"""Update the launcher, synchronize public profiles and select a configuration."""\nimport datetime\nimport hashlib\nimport json\nfrom concurrent.futures import ThreadPoolExecutor\nimport os\nfrom pathlib import Path\nimport re\nimport socket\nimport stat\nimport subprocess\nimport sys\nimport tempfile\nimport urllib.error\nimport urllib.parse\nimport urllib.request\n\nREPOSITORY_ROOT = "https://raw.githubusercontent.com/kodeops/kiosk-url-dist/main/"\nSCRIPT_URL = REPOSITORY_ROOT + "kiosk/url-kiosk.sh"\nCONFIGURATION_INDEX = "configurations/manifest.sha256"\nNETWORK_TIMEOUT = 3\nMAX_DOWNLOAD_BYTES = 2 * 1024 * 1024\nFORMAT_MARKER = b"# URL_KIOSK_DISTRIBUTION_FORMAT=1\\n"\nREEXEC_MARKER = "_URL_KIOSK_REEXEC_HASH"\n\n\ndef launcher_path():\n    return Path(os.environ["URL_KIOSK_LAUNCHER"]).resolve()\n\n\ndef report(message):\n    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")\n    print("[{}] URL Kiosk: {}".format(timestamp, message), flush=True)\n\n\ndef download(url):\n    request = urllib.request.Request(url, headers={\n        "User-Agent": "URL-Kiosk/1", "Cache-Control": "no-cache"})\n    with urllib.request.urlopen(request, timeout=NETWORK_TIMEOUT) as response:\n        data = response.read(MAX_DOWNLOAD_BYTES + 1)\n    if len(data) > MAX_DOWNLOAD_BYTES:\n        raise ValueError("Downloaded file exceeds the 2 MiB size limit")\n    return data\n\n\ndef atomic_write(path, data, mode, validator=None):\n    temporary = None\n    try:\n        with tempfile.NamedTemporaryFile(dir=path.parent, prefix="." + path.name + ".", delete=False) as stream:\n            temporary = Path(stream.name)\n            os.fchmod(stream.fileno(), mode)\n            stream.write(data)\n            stream.flush()\n            os.fsync(stream.fileno())\n        if validator:\n            validator(temporary)\n        os.replace(temporary, path)\n    finally:\n        if temporary:\n            temporary.unlink(missing_ok=True)\n\n\ndef validate_launcher(data):\n    if not data.startswith(b"#!/usr/bin/env bash\\n") or FORMAT_MARKER not in data.splitlines(keepends=True)[:5]:\n        raise ValueError("The published file is not a compatible URL Kiosk launcher")\n    opening = b"<<\'URL_KIOSK_PYTHON\'\\n"\n    closing = b"\\nURL_KIOSK_PYTHON\\n"\n    if data.count(opening) != 1 or not data.endswith(closing):\n        raise ValueError("The published launcher\'s Python payload is incomplete")\n    payload = data.split(opening, 1)[1][:-len(closing)]\n    compile(payload, "downloaded-url-kiosk", "exec")\n    result = subprocess.run(["/bin/bash", "-n"], input=data, capture_output=True, timeout=5)\n    if result.returncode:\n        raise ValueError("The published launcher failed shell syntax validation")\n\n\ndef check_for_update(arguments=None):\n    """Run before parsing config or changing X11; re-exec at most once per launch."""\n    args = sys.argv[1:] if arguments is None else arguments\n    options = args[:args.index("--")] if "--" in args else args\n    if "--no-update" in options:\n        report("Automatic launcher update skipped (--no-update).")\n        return\n    launcher = launcher_path()\n    current = launcher.read_bytes()\n    current_hash = hashlib.sha256(current).hexdigest()\n    restarted_hash = os.environ.pop(REEXEC_MARKER, None)\n    if restarted_hash == current_hash or os.environ.get("URL_KIOSK_SKIP_UPDATE") == "1":\n        return\n    report("Checking the public repository for a launcher update...")\n    try:\n        candidate = download(SCRIPT_URL)\n        if candidate == current:\n            report("Launcher is up to date.")\n            return\n        validate_launcher(candidate)\n        mode = stat.S_IMODE(launcher.stat().st_mode) | stat.S_IXUSR\n        backup = launcher.with_name(launcher.name + ".previous")\n        atomic_write(backup, current, mode)\n        atomic_write(launcher, candidate, mode)\n    except (OSError, ValueError, SyntaxError, subprocess.SubprocessError) as error:\n        if isinstance(error, urllib.error.HTTPError):\n            error.close()\n        report("Update unavailable; using the installed launcher. " + str(error))\n        return\n    report("Launcher updated; restarting with the original arguments.")\n    environment = {**os.environ, REEXEC_MARKER: hashlib.sha256(candidate).hexdigest()}\n    try:\n        os.execve("/bin/bash", ["bash", str(launcher), *args], environment)\n    except OSError as error:\n        atomic_write(launcher, current, mode)\n        report("Could not restart the update; restored the previous launcher. " + str(error))\n\n\ndef configuration_directory():\n    """Keep the public profiles beside kiosk/, preserving the dist layout."""\n    return launcher_path().parent.parent / "configurations"\n\n\ndef sync_configurations(validator):\n    """Download and validate a complete profile snapshot before replacing files."""\n    directory = configuration_directory()\n    report("Synchronizing public configurations into " + str(directory))\n    try:\n        manifest = download(REPOSITORY_ROOT + CONFIGURATION_INDEX).decode("ascii")\n        entries = {}\n        for line in manifest.splitlines():\n            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9_.-]{0,200}\\.json)", line)\n            if not match or match[2] in entries:\n                raise ValueError("Invalid or duplicate configuration manifest entry")\n            entries[match[2]] = match[1]\n        if len(entries) > 256:\n            raise ValueError("Configuration manifest exceeds the 256-profile limit")\n        if directory.is_symlink():\n            raise ValueError("Configuration directory cannot be a symbolic link")\n        marker = directory / ".url-kiosk-sync.json"\n        previous = json.loads(marker.read_text()) if marker.is_file() else []\n        if not isinstance(previous, list) or any(not isinstance(name, str) or not re.fullmatch(\n                r"[A-Za-z0-9][A-Za-z0-9_.-]{0,200}\\.json", name) for name in previous):\n            raise ValueError("Invalid local configuration sync metadata")\n        def fetch(name):\n            local = directory / name\n            if local.is_file():\n                existing = local.read_bytes()\n                if hashlib.sha256(existing).hexdigest() == entries[name]:\n                    return name, existing\n            payload = download(REPOSITORY_ROOT + "configurations/" + urllib.parse.quote(name, safe=""))\n            if hashlib.sha256(payload).hexdigest() != entries[name]:\n                raise ValueError("Configuration checksum mismatch: " + name)\n            return name, payload\n        # Parallel downloads avoid one network round trip per profile at boot.\n        with ThreadPoolExecutor(max_workers=4) as workers:\n            payloads = dict(workers.map(fetch, entries))\n        with tempfile.TemporaryDirectory(prefix="url-kiosk-profiles-") as temporary:\n            for name, payload in payloads.items():\n                staged = Path(temporary) / name\n                staged.write_bytes(payload)\n                validator(staged)\n            directory.mkdir(parents=True, exist_ok=True)\n            for name, payload in payloads.items():\n                atomic_write(directory / name, payload, 0o600)\n            for name in set(previous) - entries.keys():\n                (directory / name).unlink(missing_ok=True)\n            atomic_write(marker, json.dumps(sorted(entries)).encode(), 0o600)\n        report("Configurations synchronized: {} profile(s).".format(len(entries)))\n        return True\n    except (OSError, ValueError, UnicodeError) as error:\n        if isinstance(error, urllib.error.HTTPError):\n            error.close()\n        report("Configuration sync unavailable; using existing local files when available. " + str(error))\n        return False\n\n\ndef resolve_configuration(explicit, validator, local_profiles=False):\n    """Explicit JSON > synchronized hostname JSON > local default, with legacy lookup."""\n    if explicit is not None:\n        return explicit\n    directory = launcher_path().parent\n    default = directory / "default.json"\n    def fallback(reason):\n        if default.is_file():\n            validator(default)\n            report(reason + "; using local configuration: " + str(default))\n            return str(default)\n        raise RuntimeError(reason + "; no local default.json exists beside the launcher.")\n    hostname = socket.gethostname()\n    if len(hostname) > 253 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", hostname):\n        raise ValueError("Cannot use the machine hostname as a configuration filename: " + repr(hostname))\n    filename = hostname + ".json"\n    cached = configuration_directory() / filename\n    if cached.is_file():\n        validator(cached)\n        report("Using synchronized hostname configuration: " + str(cached))\n        return str(cached)\n    if local_profiles:\n        return fallback("No synchronized hostname configuration: " + str(cached))\n    encoded = urllib.parse.quote(filename, safe="")\n    # The build publishes maintained configs under configurations/. Root files\n    # are also accepted for repositories that already use that arrangement.\n    for relative in ("configurations/" + encoded, encoded):\n        url = REPOSITORY_ROOT + relative\n        try:\n            data = download(url)\n        except urllib.error.HTTPError as error:\n            error.close()\n            if error.code == 404:\n                continue\n            return fallback("Cannot download hostname configuration {}: {}".format(url, error))\n        except (OSError, ValueError) as error:\n            return fallback("Cannot download hostname configuration {}: {}".format(url, error))\n        destination = directory / filename\n        atomic_write(destination, data, 0o600, validator=validator)\n        report("Downloaded hostname configuration: " + str(destination))\n        return str(destination)\n    if default.is_file():\n        return fallback("Hostname configuration was not found in the public repository")\n    raise ValueError("No configuration was supplied, {} does not exist, and {} was not found in "\n                     "the public repository\'s configurations/ folder or root. "\n                     "Create default.json, publish {}, or pass a JSON filename explicitly.".format(default, filename, filename))\n', startup.__dict__)
if "--version" not in sys.argv[1:]:
    startup.check_for_update()
MONITOR_SOURCE = '#!/usr/bin/env python3\n"""Local Chrome console/network monitor. Embedded in generated kiosk scripts."""\nimport collections\nimport datetime\nimport json\nimport fcntl\nimport os\nimport re\nimport signal\nimport socket\nimport subprocess\nimport sys\nimport threading\nimport time\nimport urllib.request\n\nimport websocket\n\ndef now():\n    return datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")\n\ndef classify_browser(line):\n    # Filter the Chrome component, not matching words in a page\'s console output.\n    if re.match(r"^\\[[^\\]\\n]+:(?:VERBOSE\\d*|DEBUG|INFO|WARNING|ERROR|FATAL):google_apis[/\\\\]gcm[/\\\\][^\\]]*\\]", line):\n        return None\n    if "Created TensorFlow Lite XNNPACK delegate" in line:\n        return "INFO", "BROWSER", "Chrome initialized a CPU inference component.", False\n    if "DEPRECATED_ENDPOINT" in line:\n        return "WARN", "BROWSER", "Chrome messaging endpoint is deprecated.", False\n    if "MESA-LOADER" in line:\n        return "WARN", "GPU", line, True\n    if any(s in line.lower() for s in ("framebuffer", "webgl", "gpu process", "gpu/")):\n        return "WARN", "GPU", line, True\n    if any(s in line.lower() for s in ("error:", "fatal:", "permission denied", "failed to create data", "existing browser session")):\n        return "ERROR", "BROWSER", line, True\n    return "INFO", "BROWSER", line, False\n\nclass Monitor:\n    def __init__(self, number, name, output, url, directory):\n        self.number, self.name, self.output, self.configured = number, name, output, url\n        self.current = url\n        self.directory = directory\n        self.log_path = os.environ["KIOSK_LOG_FILE"]\n        self.lock = threading.RLock()\n        self.counts = collections.Counter()\n        self.repeats = {}\n        self.requests = {}\n        self.document_requests = {}\n        self.request_started = {}\n        self.contexts = {}\n        self.session_urls = {}\n        self.sequence = 0\n        self.ws = None\n        self.main_frame = None\n        self.started = time.monotonic()\n\n    def emit(self, level, category, message, visible=True, event_time=None, **details):\n        record = dict(timestamp=now(), level=level, category=category, display=self.number,\n                      name=self.name, output=self.output, configured_url=self.configured,\n                      page_url=self.current, message=message, **details)\n        if event_time:\n            record["event_timestamp"] = event_time\n        with self.lock:\n            self.counts[(category, level)] += 1\n            key = (level, category, message, self.current)\n            previous = self.repeats.get(key)\n            repeated = visible and previous and time.monotonic() - previous[0] < 30\n            if previous and previous[1]:\n                details["previous_repeats"] = previous[1]\n            if len(self.repeats) > 1000:\n                self.repeats.clear()\n            if not repeated:\n                self.repeats[key] = (time.monotonic(), 0)\n            text = " ".join(str(message).split())\n            if len(text) > 320:\n                text = text[:317] + "..."\n            color = {"ERROR": "\\033[31m", "WARN": "\\033[33m", "OK": "\\033[32m"}.get(level, "\\033[36m")\n            icon = {"WEBSITE": "🌐", "NETWORK": "📡", "BROWSER": "🌍", "GPU": "🎨", "SYSTEM": "⚙️"}.get(category, "📝")\n            prefix = "[{}] {} {:5} {:7} D{} [{}]".format(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), icon, level, category, self.number, self.output)\n            suffix = " ({} repeats in previous interval)".format(details["previous_repeats"]) if "previous_repeats" in details else ""\n            entry = prefix + "\\n    " + str(message) + suffix + "\\n    URL: " + self.current + "\\n    Details: " + json.dumps(record, ensure_ascii=False) + "\\n\\n"\n            with open(self.log_path, "a", encoding="utf-8") as stream:\n                fcntl.flock(stream, fcntl.LOCK_EX)\n                stream.write(entry)\n                stream.flush()\n                fcntl.flock(stream, fcntl.LOCK_UN)\n            if not visible:\n                return\n            if repeated:\n                self.repeats[key] = (previous[0], previous[1] + 1)\n                return\n            if (sys.stdout.isatty() or os.environ.get("KIOSK_COLOR")) and not os.environ.get("NO_COLOR"):\n                prefix = color + prefix + "\\033[0m"\n            suffix = " ({} repeats in previous interval)".format(details["previous_repeats"]) if "previous_repeats" in details else ""\n            # One write keeps messages from separate monitor processes legible.\n            print(prefix + "\\n    " + text + suffix + "\\n    URL: " + self.current + "\\n", flush=True)\n\n    def send(self, method, params=None, session=None):\n        self.sequence += 1\n        packet = {"id": self.sequence, "method": method, "params": params or {}}\n        if session:\n            packet["sessionId"] = session\n        self.ws.send(json.dumps(packet))\n        return self.sequence\n\n    def call(self, method, params=None):\n        wanted = self.send(method, params)\n        timeout = 60 if method == "Page.navigate" else 10\n        deadline = time.monotonic() + timeout\n        while time.monotonic() < deadline:\n            try:\n                event = json.loads(self.ws.recv())\n            except websocket.WebSocketTimeoutException:\n                continue\n            if event.get("id") == wanted:\n                if "error" in event:\n                    raise RuntimeError(method + ": " + str(event["error"]))\n                result = event.get("result", {})\n                if method == "Page.navigate" and result.get("errorText"):\n                    raise RuntimeError("Page.navigate failed: " + result["errorText"])\n                return result\n            self.event(event)\n        raise TimeoutError("{} timed out after {} seconds while waiting for Chrome diagnostics".format(method, timeout))\n\n    def event(self, packet):\n        method, p, session = packet.get("method", ""), packet.get("params", {}), packet.get("sessionId", "")\n        if "error" in packet:\n            self.emit("WARN", "SYSTEM", "A diagnostic command was rejected", visible=False, detail=packet)\n            return\n        if method == "Target.attachedToTarget":\n            sid = p["sessionId"]\n            target = p.get("targetInfo", {})\n            self.session_urls[sid] = target.get("url", "")\n            for domain in ("Runtime", "Log", "Network"):\n                self.send(domain + ".enable", session=sid)\n            self.send("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": False, "flatten": True}, sid)\n            self.send("Runtime.runIfWaitingForDebugger", session=sid)\n        elif method == "Runtime.executionContextCreated":\n            context = p["context"]\n            self.contexts[(session, context["id"])] = context.get("origin", "")\n        elif method == "Runtime.executionContextsCleared":\n            self.contexts = {k: v for k, v in self.contexts.items() if k[0] != session}\n        elif method == "Runtime.consoleAPICalled":\n            args = p.get("args", [])\n            message = " ".join(str(a.get("value", a.get("description", a.get("type", "")))) for a in args)\n            self.emit("WARN" if p["type"] == "warning" else "ERROR" if p["type"] in ("error", "assert") else "INFO", "WEBSITE", message, visible=p["type"] in ("error", "warning", "assert"),\n                      event_time=p.get("timestamp"), source="console." + p["type"],\n                      execution_origin=self.contexts.get((session, p.get("executionContextId"))),\n                      target_url=self.session_urls.get(session), stack=p.get("stackTrace"), arguments=args)\n        elif method == "Runtime.exceptionThrown":\n            error = p.get("exceptionDetails", {})\n            message = error.get("exception", {}).get("description", error.get("text", "Unhandled exception"))\n            self.emit("ERROR", "WEBSITE", message, event_time=p.get("timestamp"),\n                      source="javascript-exception", source_url=error.get("url"),\n                      line=error.get("lineNumber", 0) + 1, column=error.get("columnNumber", 0) + 1,\n                      target_url=self.session_urls.get(session), stack=error.get("stackTrace"))\n        elif method == "Log.entryAdded":\n            entry = p["entry"]\n            if entry.get("level") not in ("warning", "error") or entry.get("source") == "network":\n                return\n            source = entry.get("source", "")\n            category = "GPU" if source == "rendering" else "WEBSITE" if source in ("javascript", "security", "deprecation", "violation") else "BROWSER"\n            self.emit("ERROR" if entry["level"] == "error" else "WARN", category, entry.get("text", ""),\n                      event_time=entry.get("timestamp"), source=source, source_url=entry.get("url"), stack=entry.get("stackTrace"))\n        elif method == "Network.requestWillBeSent":\n            key = (session, p["requestId"])\n            if len(self.requests) > 5000:\n                self.requests.clear()\n                self.request_started.clear()\n            self.requests[key] = p["request"].get("url", "")\n            self.request_started[key] = time.monotonic()\n            if p.get("type") == "Document":\n                if len(self.document_requests) > 1000:\n                    self.document_requests.clear()\n                self.document_requests[key] = (self.requests[key], time.monotonic())\n                self.emit("INFO", "NETWORK", "Document request started {:.2f}s after Chrome launch".format(\n                    time.monotonic() - self.started), resource_url=self.requests[key], source="document-timing")\n        elif method == "Network.responseReceived":\n            response = p["response"]\n            if p.get("type") == "Document":\n                self.emit("INFO", "NETWORK", "Document response HTTP {} after {:.2f}s".format(\n                    response.get("status"), time.monotonic() - self.started), resource_url=response.get("url"),\n                    timing=response.get("timing"), source="document-timing")\n            if response.get("status", 0) >= 400:\n                self.emit("ERROR", "NETWORK", "HTTP {}".format(response["status"]),\n                          resource_url=response.get("url"), http_status=response["status"], source="http-response")\n        elif method == "Network.loadingFailed":\n            self.document_requests.pop((session, p["requestId"]), None)\n            self.request_started.pop((session, p["requestId"]), None)\n            resource = self.requests.pop((session, p["requestId"]), "")\n            canceled = p.get("canceled", False)\n            self.emit("INFO" if canceled else "ERROR", "NETWORK", p.get("errorText", "Request failed"),\n                      visible=not canceled, resource_url=resource, source="request-failed",\n                      blocked_reason=p.get("blockedReason"), cors=p.get("corsErrorStatus"), canceled=canceled)\n        elif method == "Network.loadingFinished":\n            key = (session, p["requestId"])\n            started = self.request_started.pop(key, None)\n            if started is not None and time.monotonic() - started >= 2 and key not in self.document_requests:\n                self.emit("INFO", "NETWORK", "Slow resource downloaded in {:.2f}s".format(time.monotonic() - started),\n                          resource_url=self.requests.get(key, ""), source="resource-timing")\n            document = self.document_requests.pop((session, p["requestId"]), None)\n            if document:\n                self.emit("OK", "NETWORK", "Document downloaded in {:.2f}s".format(time.monotonic() - document[1]),\n                          resource_url=document[0], source="document-timing")\n            self.requests.pop((session, p["requestId"]), None)\n        elif method == "Page.frameNavigated":\n            frame = p["frame"]\n            if not session and not frame.get("parentId"):\n                self.main_frame = frame["id"]\n                self.current = frame.get("url", self.current)\n                self.emit("OK", "SYSTEM", "Page navigation", source="navigation")\n            elif session and not frame.get("parentId"):\n                self.session_urls[session] = frame.get("url", "")\n        elif method == "Page.lifecycleEvent":\n            if not session and p.get("frameId") == self.main_frame and p.get("name") in ("firstContentfulPaint", "load"):\n                self.emit("OK", "SYSTEM", "Page {} observed {:.2f}s after Chrome launch".format(\n                    p["name"], time.monotonic() - self.started), source="startup-timing", lifecycle=p["name"])\n        elif method == "Inspector.targetCrashed":\n            self.emit("ERROR", "BROWSER", "Renderer target crashed", source="renderer-crash")\n\n    def stderr(self, stream):\n        for line in stream:\n            line = line.rstrip()\n            classification = classify_browser(line)\n            if classification is None:\n                continue\n            level, category, message, visible = classification\n            self.emit(level, category, message, visible=visible, source="chrome-stderr", raw=line)\n\n    def fullscreen(self, x, y, width, height):\n        """Retry asynchronous X11 placement and confirm fullscreen on the target output."""\n        x, y, width, height = map(int, (x, y, width, height))\n        window_id = self.call("Browser.getWindowForTarget")["windowId"]\n        bounds = {}\n        def on_target(value):\n            if not all(key in value for key in ("left", "top", "width", "height")):\n                return False\n            cx, cy = value["left"] + value["width"] / 2, value["top"] + value["height"] / 2\n            return x <= cx < x + width and y <= cy < y + height\n        for attempt in range(4):\n            self.call("Browser.setWindowBounds", {"windowId": window_id, "bounds": {"windowState": "normal"}})\n            self.call("Browser.setWindowBounds", {"windowId": window_id, "bounds": {\n                "left": x, "top": y, "width": width, "height": height}})\n            for _ in range(10):\n                bounds = self.call("Browser.getWindowBounds", {"windowId": window_id})["bounds"]\n                if on_target(bounds):\n                    break\n                time.sleep(0.05)\n            else:\n                continue\n            self.call("Browser.setWindowBounds", {"windowId": window_id, "bounds": {"windowState": "fullscreen"}})\n            for _ in range(10):\n                bounds = self.call("Browser.getWindowBounds", {"windowId": window_id})["bounds"]\n                if bounds.get("windowState") == "fullscreen" and on_target(bounds):\n                    self.emit("OK", "SYSTEM", "Fullscreen confirmed", bounds=bounds, placement_attempt=attempt + 1)\n                    return\n                time.sleep(0.05)\n        raise RuntimeError("Window placement not confirmed after 4 attempts; requested {}x{} at {},{}; observed {}".format(\n            width, height, x, y, bounds))\n\n    def summary(self):\n        with self.lock:\n            counts = ", ".join("{} {}={}".format(c, l, n) for (c, l), n in sorted(self.counts.items()) if l in ("ERROR", "WARN")) or "no warnings or errors captured"\n        self.emit("INFO", "SYSTEM", "Summary: " + counts)\n\ndef fullscreen_x11(monitor, process, x, y, width, height):\n    """Use the original wmctrl launch path without attaching to a renderer."""\n    x, y, width, height = map(int, (x, y, width, height))\n    expected_class = "urlkiosk" + monitor.number\n\n    def command(args):\n        result = subprocess.run(["wmctrl", *args], capture_output=True, text=True, timeout=2)\n        if result.returncode:\n            raise RuntimeError("wmctrl failed: " + (result.stderr.strip() or str(result.returncode)))\n        return result.stdout\n\n    def windows():\n        for line in command(["-lGx"]).splitlines():\n            fields = line.split(None, 8)\n            if len(fields) >= 7 and expected_class in fields[6].lower().split("."):\n                yield fields[0], tuple(map(int, fields[2:6]))\n\n    deadline = time.monotonic() + 6\n    window_id = None\n    while time.monotonic() < deadline and process.poll() is None:\n        window_id = next((identifier for identifier, _ in windows()), None)\n        if window_id:\n            break\n        time.sleep(0.05)\n    if not window_id:\n        raise RuntimeError("Could not find the Chrome window for " + monitor.name)\n    for _ in range(4):\n        command(["-i", "-r", window_id, "-b", "remove,fullscreen,maximized_vert"])\n        command(["-i", "-r", window_id, "-b", "remove,maximized_horz"])\n        command(["-i", "-r", window_id, "-e", "0,{},{},{},{}".format(x, y, width, height)])\n        for _ in range(10):\n            bounds = next((bounds for identifier, bounds in windows() if identifier == window_id), None)\n            if bounds:\n                left, top, w, h = bounds\n                if x <= left + w / 2 < x + width and y <= top + h / 2 < y + height:\n                    command(["-i", "-r", window_id, "-b", "add,fullscreen"])\n                    monitor.emit("OK", "SYSTEM", "Fullscreen requested through X11; no DevTools connection", window_id=window_id)\n                    return\n            time.sleep(0.05)\n    raise RuntimeError("X11 window placement not confirmed for " + monitor.name)\n\ndef main():\n    number, name, output, url, profile, directory, browser, x, y, width, height = sys.argv[1:12]\n    flags = sys.argv[12:]\n    # Openbox/autologin may leave the desktop keyring unavailable or locked.\n    # Avoid blocking initial navigation on it in these dedicated kiosk profiles.\n    if not any(flag.split("=", 1)[0] == "--password-store" for flag in flags):\n        flags = ["--password-store=basic", *flags]\n    monitor = Monitor(number, name, output, url, directory)\n    minimal = os.environ.get("URL_KIOSK_MINIMAL") == "1"\n    os.makedirs(profile, exist_ok=True)\n    command = [browser, *flags, "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check",\n               "--disable-session-crashed-bubble", "--new-window", "--app=" + url, "--class=UrlKiosk" + number,\n               "--window-position=" + x + "," + y, "--window-size=" + width + "," + height]\n    if not minimal:\n        # A fresh port on loopback for this independent profile.\n        with socket.socket() as server:\n            server.bind(("127.0.0.1", 0))\n            port = server.getsockname()[1]\n        command += ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=" + str(port)]\n    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")\n    reader = threading.Thread(target=monitor.stderr, args=(process.stdout,), daemon=True)\n    reader.start()\n    monitor.emit("INFO", "SYSTEM", "Starting " + name + "; Chrome is loading the configured URL directly")\n    def stop(_signum, _frame):\n        if process.poll() is None:\n            process.terminate()\n        raise KeyboardInterrupt\n    signal.signal(signal.SIGTERM, stop)\n    signal.signal(signal.SIGINT, stop)\n    try:\n        if minimal:\n            monitor.emit("WARN", "SYSTEM", "Minimal startup: web console/network monitoring disabled; Chrome/GPU and system logs remain active")\n            try:\n                fullscreen_x11(monitor, process, x, y, width, height)\n            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:\n                monitor.emit("ERROR", "SYSTEM", str(error) + "; Chrome remains open", source="window-placement")\n            result = process.wait()\n            monitor.emit("INFO" if result == 0 else "ERROR", "BROWSER", "Chrome exited with code " + str(result), source="process-exit")\n            return result\n        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))\n        deadline = time.monotonic() + 25\n        while time.monotonic() < deadline:\n            if process.poll() is not None:\n                raise RuntimeError("Chrome exited before monitoring connected. Close existing windows using this profile, then relaunch.")\n            try:\n                with opener.open("http://127.0.0.1:" + str(port) + "/json/list", timeout=1) as response:\n                    targets = json.load(response)\n                page = next((t for t in targets if t.get("type") == "page" and "webSocketDebuggerUrl" in t), None)\n                if page:\n                    monitor.ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=1,\n                                                             suppress_origin=True, http_no_proxy=["127.0.0.1", "localhost"])\n                    break\n            except (OSError, ValueError, websocket.WebSocketException):\n                pass\n            time.sleep(0.2)\n        if monitor.ws is None:\n            raise RuntimeError("Could not connect to Chrome diagnostics on loopback.")\n        monitor.emit("INFO", "SYSTEM", "Chrome diagnostics available after {:.2f}s".format(time.monotonic() - monitor.started))\n        for domain in ("Runtime", "Log", "Network", "Page", "Inspector"):\n            monitor.call(domain + ".enable")\n        monitor.call("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": False, "flatten": True})\n        try:\n            monitor.fullscreen(x, y, width, height)\n        except (RuntimeError, TimeoutError) as error:\n            monitor.emit("ERROR", "SYSTEM", str(error) + "; Chrome remains open", source="window-placement")\n        monitor.send("Page.setLifecycleEventsEnabled", {"enabled": True})\n        monitor.emit("OK", "SYSTEM", "Console and network monitoring connected after {:.2f}s".format(time.monotonic() - monitor.started))\n        try:\n            frame = monitor.call("Page.getFrameTree").get("frameTree", {}).get("frame", {})\n            monitor.main_frame = frame.get("id")\n            monitor.current = frame.get("url") or monitor.current\n            timing = monitor.call("Runtime.evaluate", {\n                "expression": "JSON.stringify({readyState:document.readyState,navigation:performance.getEntriesByType(\'navigation\').map(n=>({dns_ms:n.domainLookupEnd-n.domainLookupStart,connect_ms:n.connectEnd-n.connectStart,response_start_ms:n.responseStart,response_end_ms:n.responseEnd,dom_ready_ms:n.domContentLoadedEventEnd,load_ms:n.loadEventEnd})),paint:performance.getEntriesByType(\'paint\').map(p=>({name:p.name,start_ms:p.startTime}))})",\n                "returnByValue": True})\n            monitor.emit("INFO", "SYSTEM", "Page startup timing snapshot", visible=False,\n                         source="startup-timing", timing=timing.get("result", {}).get("value"))\n        except (RuntimeError, TimeoutError) as error:\n            monitor.emit("WARN", "SYSTEM", "Startup timing snapshot unavailable: " + str(error), visible=False)\n\n        last_summary = time.monotonic()\n        while process.poll() is None:\n            try:\n                monitor.event(json.loads(monitor.ws.recv()))\n            except websocket.WebSocketTimeoutException:\n                pass\n            except websocket.WebSocketConnectionClosedException:\n                monitor.emit("WARN", "SYSTEM", "Diagnostic connection closed; console capture stopped")\n                break\n            if time.monotonic() - last_summary >= 60:\n                monitor.summary()\n                last_summary = time.monotonic()\n        # Do not terminate a working browser merely because its diagnostics disconnected.\n        process.wait()\n        reader.join(timeout=2)\n        monitor.summary()\n        monitor.emit("INFO" if process.returncode == 0 else "ERROR", "BROWSER",\n                     "Chrome exited with code " + str(process.returncode), source="process-exit")\n        return process.returncode\n    except KeyboardInterrupt:\n        monitor.summary()\n        monitor.emit("INFO", "SYSTEM", "Monitor stopped")\n        return 0\n    except Exception as error:\n        monitor.emit("ERROR", "SYSTEM", str(error), source="monitor-failure")\n        # Diagnostics/placement errors must not close a browser that is still working.\n        try:\n            return process.wait()\n        except KeyboardInterrupt:\n            return 0\n    finally:\n        # Wait for owned Chrome processes to finish during shutdown.\n        if process.poll() is None:\n            process.terminate()\n            try:\n                process.wait(timeout=8)\n            except subprocess.TimeoutExpired:\n                process.kill()\n                process.wait()\n        reader.join(timeout=2)\n        if monitor.ws:\n            monitor.ws.close()\n\nif __name__ == "__main__":\n    sys.exit(main())\n'
#!/usr/bin/env python3
"""Validate a JSON configuration and supervise a parallel X11 kiosk session."""
import argparse
import ctypes
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

try:
    from url_kiosk_bootstrap import resolve_configuration, sync_configurations
except ImportError:
    from src.bootstrap import resolve_configuration, sync_configurations

KIOSK_VERSION = globals().get("KIOSK_VERSION", "development")


class CursorHider:
    """Keep the X11 cursor hidden until this client's connection is closed."""
    def __init__(self):
        self.display = None
        self.roots = []
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.fixes = ctypes.CDLL("libXfixes.so.3")
        pointer, integer, window = ctypes.c_void_p, ctypes.c_int, ctypes.c_ulong
        for library, name, arguments, result in (
            (self.x11, "XOpenDisplay", [ctypes.c_char_p], pointer),
            (self.x11, "XScreenCount", [pointer], integer),
            (self.x11, "XRootWindow", [pointer, integer], window),
            (self.x11, "XSync", [pointer, integer], integer),
            (self.x11, "XCloseDisplay", [pointer], integer),
            (self.fixes, "XFixesQueryVersion", [pointer, ctypes.POINTER(integer), ctypes.POINTER(integer)], integer),
            (self.fixes, "XFixesHideCursor", [pointer, window], None),
            (self.fixes, "XFixesShowCursor", [pointer, window], None),
        ):
            function = getattr(library, name)
            function.argtypes, function.restype = arguments, result
        self.display = self.x11.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("Cannot open the X display to hide the cursor")
        try:
            major, minor = integer(4), integer(0)
            if not self.fixes.XFixesQueryVersion(self.display, ctypes.byref(major), ctypes.byref(minor)) or major.value < 4:
                raise RuntimeError("Cursor hiding requires XFixes version 4 or later")
            for screen in range(self.x11.XScreenCount(self.display)):
                root = self.x11.XRootWindow(self.display, screen)
                self.fixes.XFixesHideCursor(self.display, root)
                self.roots.append(root)
            self.x11.XSync(self.display, False)
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.display:
            for root in self.roots:
                self.fixes.XFixesShowCursor(self.display, root)
            self.x11.XSync(self.display, False)
            self.x11.XCloseDisplay(self.display)
            self.display = None


def configuration(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return validate_configuration(data)


def validate_configuration(data):
    """Validate configuration data without accessing X11 or starting Chrome."""
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1:
        raise ValueError("Configuration version must be 1.")
    browser = data.get("browser", "google-chrome")
    if not isinstance(browser, str) or not re.fullmatch(r"[A-Za-z0-9._/-]+", browser):
        raise ValueError("Invalid browser executable.")
    delay = data.get("delay", 0)
    if type(delay) not in (int, float) or not math.isfinite(delay) or not 0 <= delay <= 60:
        raise ValueError("Delay must be between 0 and 60 seconds.")
    flags = data.get("flags", [])
    if not isinstance(flags, list) or not all(isinstance(x, str) and x.startswith("--") and "\x00" not in x for x in flags):
        raise ValueError("Flags must be an array of Chrome --options.")
    reserved = ("--user-data-dir", "--remote-debugging", "--window-", "--app", "--class", "--headless", "--kiosk", "--start-fullscreen")
    if any(flag.startswith(reserved) for flag in flags):
        raise ValueError("Flags cannot override profile, diagnostics or window placement.")
    screens = data.get("screens")
    if not isinstance(screens, list) or len(screens) < 1:
        raise ValueError("Configure at least one display.")
    disabled = data.get("disabled", [])
    if not isinstance(disabled, list):
        raise ValueError("Disabled outputs must be an array.")
    def output(value):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", value):
            raise ValueError("Invalid output name.")
        return value
    disabled = [output(x) for x in disabled]
    active, cursor, outputs = [], 0, set()
    for number, screen in enumerate(screens, 1):
        if not isinstance(screen, dict) or type(screen.get("on", True)) is not bool:
            raise ValueError("Each display must be an object with a boolean on field.")
        if not screen.get("on", True):
            # Not launching a kiosk must not change this output's desktop state.
            continue
        out = output(screen.get("out"))
        if out in outputs or out in disabled:
            raise ValueError("Enabled outputs must be unique and cannot also be disabled.")
        outputs.add(out)
        resolution = screen.get("res", "")
        if not isinstance(resolution, str) or not re.fullmatch(r"[1-9][0-9]{1,4}x[1-9][0-9]{1,4}", resolution):
            raise ValueError("Invalid display resolution.")
        width, height = map(int, resolution.split("x"))
        rotation = screen.get("rot", "normal")
        if rotation not in ("normal", "left", "right", "inverted"):
            raise ValueError("Invalid display rotation.")
        hz = screen.get("hz", 60)
        if isinstance(hz, bool) or not re.fullmatch(r"\d+(?:\.\d+)?", str(hz)) or not 1 <= float(hz) <= 240:
            raise ValueError("Refresh rate must be between 1 and 240 Hz.")
        url, name = screen.get("url"), screen.get("name", "Display " + str(number))
        if not isinstance(url, str) or not re.match(r"^https?://[^\s/]+", url) or any(ord(c) < 32 for c in url):
            raise ValueError("Display URLs must use http:// or https://.")
        if not isinstance(name, str) or not name.strip() or any(ord(c) < 32 for c in name):
            raise ValueError("Display names must be nonempty single-line strings.")
        if rotation in ("left", "right"):
            width, height = height, width
        active.append(dict(number=number, name=name, out=out, res=resolution, rot=rotation,
                           hz=str(hz), url=url, x=cursor, width=width, height=height))
        cursor += width
    if not active:
        raise ValueError("Enable at least one display.")
    primary = data.get("primary", active[0]["out"])
    if not isinstance(primary, str) or primary not in outputs:
        raise ValueError("Primary display must reference an enabled output.")
    # Let XRandR size the framebuffer to include outputs outside this configuration.
    xr = ["xrandr"]
    for index, screen in enumerate(active):
        xr += ["--output", screen["out"], "--mode", screen["res"], "--rate", screen["hz"],
               "--rotate", screen["rot"], "--pos", str(screen["x"]) + "x0"]
        if screen["out"] == primary:
            xr += ["--primary"]
    return dict(browser=browser, delay=delay, flags=flags, disabled=disabled, active=active, primary=primary, xrandr=xr)


def xrandr_outputs(text):
    """Read connector names and active desktop geometry from xrandr --query."""
    outputs = {}
    for line in text.splitlines():
        match = re.match(r"^(\S+)\s+(connected|disconnected)\b(.*)$", line)
        if not match:
            continue
        name, state, rest = match.groups()
        geometry = re.match(r"\s+(?:primary\s+)?(\d+)x(\d+)([+-]\d+)([+-]\d+)\b", rest)
        outputs[name] = dict(connected=state == "connected", geometry=(
            tuple(map(int, geometry.groups())) if geometry else None))
    return outputs


def check_outputs(settings, outputs, applied=False):
    connected = ", ".join(name for name, data in outputs.items() if data["connected"]) or "none"
    for screen in settings["active"]:
        name = screen["out"]
        if name not in outputs or not outputs[name]["connected"]:
            raise RuntimeError("Configured output {} is not connected. Connected outputs: {}. "
                               "Update the JSON screen out field and primary output for this computer.".format(name, connected))
        if applied:
            expected = (screen["width"], screen["height"], screen["x"], 0)
            actual = outputs[name]["geometry"]
            if actual != expected:
                raise RuntimeError("Display layout was not applied for {}: expected (width, height, x, y) {}, "
                                   "but xrandr reports {}. Chrome was not started.".format(name, expected, actual))


def boot_wallpaper_commands():
    """Paint Openbox before network/configuration work; XRandR reapplies it later."""
    return '''{
  if [[ ! -f streamflow-bg.png ]]; then
    echo "WARN: Startup wallpaper not found: $PWD/streamflow-bg.png"
  elif ! command -v feh >/dev/null 2>&1; then
    echo 'WARN: Startup wallpaper requires feh.'
  elif feh --no-fehbg --bg-fill "$PWD/streamflow-bg.png"; then
    echo "Startup wallpaper applied: $PWD/streamflow-bg.png"
  else
    echo 'WARN: Could not apply startup wallpaper; kiosk will retry after display setup.'
  fi
} >>kiosk-startup.log 2>&1
'''


def install_autostart(config, launcher):
    """Install dynamic hostname startup or an explicitly supplied fixed boot JSON."""
    home = Path.home()
    if config is None:
        launcher = Path(launcher).resolve()
        wrapper = home / ".local/bin/run-kiosk.sh"
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        if wrapper.exists():
            shutil.copyfile(wrapper, wrapper.with_name("run-kiosk.sh.backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")))
        wrapper.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' +
                           'cd -- ' + shlex.quote(str(launcher.parent)) + '\n' +
                           boot_wallpaper_commands() +
                           'exec /bin/bash ' + shlex.quote(str(launcher)) + ' >>kiosk-startup.log 2>&1\n')
        wrapper.chmod(0o755)
        install_openbox_entry(wrapper)
        print("Automatic configuration: remote hostname.json, then local default.json.")
        return
    destination = home / ".local/bin/url-kiosk.sh"
    boot = home / ".config/url-kiosk/boot.json"
    wrapper = home / ".local/bin/run-kiosk.sh"
    destination.parent.mkdir(parents=True, exist_ok=True)
    boot.parent.mkdir(parents=True, exist_ok=True)
    if Path(launcher).resolve() != destination.resolve():
        shutil.copyfile(launcher, destination)
    destination.chmod(0o755)
    background = Path(launcher).resolve().parent / "streamflow-bg.png"
    installed_background = destination.parent / background.name
    if background.is_file() and background.resolve() != installed_background.resolve():
        shutil.copyfile(background, installed_background)
    if Path(config).resolve() != boot.resolve():
        if boot.exists():
            shutil.copyfile(boot, boot.with_name("boot.json.backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")))
        shutil.copyfile(config, boot)
    boot.chmod(0o600)
    wrapper.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' +
                      'export URL_KIOSK_LOG_DIR=' + shlex.quote(str(Path(launcher).resolve().parent)) + '\n' +
                      'cd -- ' + shlex.quote(str(Path(launcher).resolve().parent)) + '\n' +
                      boot_wallpaper_commands() +
                      'exec ' + shlex.join([str(destination), str(boot)]) + '\n')
    wrapper.chmod(0o755)
    install_openbox_entry(wrapper)
    print("Boot configuration: " + str(boot))


def install_openbox_entry(wrapper):
    """Replace the managed autostart block while preserving unrelated entries."""
    home = Path.home()
    autostart = home / ".config/openbox/autostart"
    autostart.parent.mkdir(parents=True, exist_ok=True)
    existing = autostart.read_text() if autostart.exists() else ""
    if autostart.exists():
        shutil.copyfile(autostart, autostart.with_name("autostart.backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")))
    existing = re.sub(r"(?ms)^# BEGIN (?:URL|QUAD)-KIOSK\n.*?^# END (?:URL|QUAD)-KIOSK\n?", "", existing)
    command = shlex.join([str(wrapper)])
    autostart.write_text(existing.rstrip() + "\n# BEGIN URL-KIOSK\n( " + command +
                         " >/dev/null 2>&1 ) &\n# END URL-KIOSK\n")
    print("Openbox autostart installed: " + str(wrapper))


def run(settings, minimal=False):
    import websocket  # Check the Ubuntu dependency before changing the display layout.
    browser = os.environ.get("CHROME_BIN", settings["browser"])
    dependencies = (browser, "xrandr", "xset") + (("wmctrl",) if minimal else ())
    for dependency in dependencies:
        if not shutil.which(dependency):
            raise ValueError("Missing dependency: " + dependency)
    os.environ.setdefault("DISPLAY", ":0")
    os.environ.setdefault("XAUTHORITY", str(Path.home() / ".Xauthority"))
    launcher_directory = Path(os.environ.get("URL_KIOSK_LAUNCHER", __file__)).resolve().parent
    root = Path(os.environ.get("URL_KIOSK_LOG_DIR", str(launcher_directory))).resolve()
    log = root / datetime.datetime.now().strftime("url-kiosk_%Y-%m-%d_%H-%M-%S.log")
    # Exclusive creation prevents two runs from sharing the same timestamped log.
    with log.open("x", encoding="utf-8"):
        pass
    os.environ["KIOSK_LOG_FILE"] = str(log)
    print("URL KIOSK | Log: " + str(log), flush=True)
    def entry(message):
        with log.open("a", encoding="utf-8") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(datetime.datetime.now().strftime("[%Y-%m-%d %H:%M:%S] ⚙️ SYSTEM\n    ") + message + "\n\n")
    def command(args, check=True, env=None):
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", env=env)
        entry(shlex.join(args) + "\n" + result.stdout)
        if check and result.returncode:
            detail = result.stdout.strip() or "The command produced no diagnostic output."
            raise RuntimeError("Command failed (exit {}): {}\n{}\nLog: {}".format(
                result.returncode, shlex.join(args), detail, log))
        return result
    processes = []
    cursor = None
    def stop(_signum, _frame):
        raise KeyboardInterrupt
    previous_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        entry("Launcher commit: " + KIOSK_VERSION)
        entry("Startup mode: " + ("minimal (X11 placement; web monitoring disabled)" if minimal else "web monitoring enabled"))
        entry('DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority" xrandr --query')
        inventory = command(["xrandr", "--query"], env={**os.environ, "DISPLAY": ":0", "XAUTHORITY": str(Path.home() / ".Xauthority")})
        outputs = xrandr_outputs(inventory.stdout)
        check_outputs(settings, outputs)
        for args in (["xset", "s", "off"], ["xset", "-dpms"], ["xset", "s", "noblank"]):
            command(args, check=False)
        for out in settings["disabled"]:
            if out not in outputs:
                entry("WARN: Skipping disabled output that does not exist on this computer: " + out)
                continue
            command(["xrandr", "--output", out, "--off"], check=False)
        command(settings["xrandr"])
        applied = command(["xrandr", "--query"])
        check_outputs(settings, xrandr_outputs(applied.stdout), applied=True)
        entry("Configured output geometry verified before Chrome startup")
        wallpaper = launcher_directory / "streamflow-bg.png"
        if not wallpaper.is_file():
            entry("WARN: Wallpaper not found: " + str(wallpaper))
        elif not shutil.which("feh"):
            entry("WARN: Install wallpaper support: sudo apt install -y feh")
        else:
            result = command(["feh", "--no-fehbg", "--bg-fill", str(wallpaper)], check=False)
            if result.returncode:
                entry("WARN: Wallpaper could not be applied; see feh output above")
            else:
                entry("Wallpaper applied to the configured monitor layout")
        time.sleep(settings["delay"])
        try:
            cursor = CursorHider()
            entry("Mouse cursor hidden for the kiosk session")
        except (OSError, AttributeError, RuntimeError) as error:
            warning = "WARN: Could not hide the mouse cursor: " + str(error)
            entry(warning)
            print("URL Kiosk: " + warning, file=sys.stderr, flush=True)
        profiles = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "url-kiosk"
        profiles.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="url-kiosk-") as temporary:
            monitor = Path(temporary) / "monitor.py"
            monitor.write_text(MONITOR_SOURCE, encoding="utf-8")
            try:
                for screen in settings["active"]:
                    number = str(screen["number"])
                    args = [sys.executable, "-u", str(monitor), number, screen["name"], screen["out"], screen["url"],
                            str(profiles / ("chrome-screen-" + number)), temporary, browser,
                            str(screen["x"]), "0", str(screen["width"]), str(screen["height"]), *settings["flags"]]
                    processes.append(subprocess.Popen(args, env={**os.environ, "URL_KIOSK_MINIMAL": "1" if minimal else "0"}))
                codes = [process.wait() for process in processes]
                return int(any(codes))
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                for process in processes:
                    try:
                        process.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    except KeyboardInterrupt:
        entry("Session stopped")
        return 130
    except Exception as error:
        entry("ERROR: " + str(error))
        raise
    finally:
        if cursor:
            cursor.close()
            entry("Kiosk cursor hiding released")
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description="Run Chrome on configured X11 displays.")
    parser.add_argument("--version", action="version", version="URL Kiosk | Commit: " + KIOSK_VERSION)
    parser.add_argument("--no-update", action="store_true", help="Skip launcher and profile updates for this run")
    parser.add_argument("configuration", nargs="?", help="JSON path; otherwise download hostname.json, falling back to local default.json")
    parser.add_argument("--check", action="store_true", help="Validate configuration without starting Chrome")
    parser.add_argument("--install-autostart", action="store_true", help="Install Openbox autostart; omit JSON for hostname/default selection")
    parser.add_argument("--minimal", action="store_true", help="Compare startup without DevTools or web monitoring; requires wmctrl")
    args = parser.parse_args()
    print("URL Kiosk | Commit: " + KIOSK_VERSION, flush=True)
    try:
        if args.minimal and args.install_autostart:
            raise ValueError("--minimal is a manual startup comparison; do not combine it with --install-autostart.")
        if args.install_autostart and args.configuration is None and not args.check:
            install_autostart(None, os.environ["URL_KIOSK_LAUNCHER"])
            return 0
        skip_updates = args.no_update or os.environ.get("URL_KIOSK_SKIP_UPDATE") == "1"
        synchronized = False
        if not skip_updates and not args.check and not args.install_autostart:
            synchronized = sync_configurations(configuration)
        args.configuration = resolve_configuration(args.configuration, configuration,
                                                 local_profiles=skip_updates or synchronized)
        settings = configuration(args.configuration)
        if args.check:
            print("Configuration valid: " + str(len(settings["active"])) + " enabled display(s).")
            return 0
        if args.install_autostart:
            install_autostart(args.configuration, os.environ["URL_KIOSK_LAUNCHER"])
            return 0
        return run(settings, minimal=args.minimal)
    except (ValueError, OSError, RuntimeError, ImportError) as error:
        print("URL Kiosk: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

URL_KIOSK_PYTHON
