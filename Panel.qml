import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import QtMultimedia
import qs.Commons
import qs.Ui
import "components"

Panel {
    id: root
    moduleName: "tenzin.omamovie"

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root

    function sanitize(s) {
        if (!s) return "";
        return String(s).replace(/<[^>]*>/g, "");
    }
    function friendlyText(s) {
        var text = root.sanitize(s || "");
        text = text.replace(/torrentsdb/gi, "FastDB");
        text = text.replace(/torrentio/gi, "IO Streams");
        text = text.replace(/\btorrents?\b/gi, "Community Streams");
        text = text.replace(/\binfo[ -]?hash\b/gi, "Stream ID");
        text = text.replace(/\b[0-9a-f]{40}\b/gi, "");
        return text.replace(/\s{2,}/g, " ").trim();
    }
    function sanitizeDetails(d) {
        if (!d) return null;
        var out = {};
        for (var k in d) {
            var v = d[k];
            if (typeof v === "string") out[k] = root.currentProvider === "stremio" ? root.friendlyText(v) : root.sanitize(v);
            else if (Array.isArray(v)) out[k] = v.map(function(x) { return typeof x === "string" ? root.sanitize(x) : x; });
            else out[k] = v;
        }
        return out;
    }
    function sanitizeStreams(arr) {
        if (!Array.isArray(arr)) return [];
        var clean = arr.map(function(s) {
            var out = {};
            for (var k in s) {
                var v = s[k];
                if (typeof v === "string") out[k] = root.sanitize(v);
                else out[k] = v;
            }
            return out;
        });
        clean.sort(function(a, b) {
            var resolution = Number(b.resolution || 0) - Number(a.resolution || 0);
            if (resolution !== 0) return resolution;
            var seeders = Number(b.seeders || 0) - Number(a.seeders || 0);
            if (seeders !== 0) return seeders;
            return Number(b.size || 0) - Number(a.size || 0);
        });
        return clean;
    }

    readonly property string bridge: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omamovie/omamovie-bridge"
    readonly property string mpvCacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omamovie/mpv-cache"
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"

    implicitWidth: 820
    implicitHeight: 560

    // ---------------- state ----------------
    property string view: "home"          // home | discover | grid | details | library | calendar | player
    // One place to silence the theme, so every way out of a details page is
    // covered without threading a call through each navigation function.
    onViewChanged: {
        if (root.view !== "details") root.stopTheme();
        // Leaving the page without playing: hand back any engine a prefetch
        // started, rather than leaving a swarm alive behind a closed panel.
        if (root.view !== "details" && !root.playing) root.clearPrefetch(true);
    }
    property var details: null
    property string currentId: ""
    property string currentTitle: ""
    property string provider: "stremio"
    property string currentProvider: "stremio"
    property var seasons: []
    property int curSeason: 1
    property int maxEp: 0
    property int curEp: 0                 // 0 = movie
    property var streams: []
    property int selStream: -1
    property var subs: []
    property bool captionsBusy: false
    property int captionsGen: 0
    property string selectedSubtitle: "auto"
    property var audioOptions: []
    property int selectedAudio: -1
    property bool audioExplicit: false
    property bool busy: false
    property string busyLabel: ""
    property string statusText: "Discover popular and new TV shows and movies"
    property string query: ""
    property var results: []
    property bool playing: false
    property bool streamConnecting: false
    property var warmupArgs: []
    property string warmupLink: ""
    property string warmupLabel: ""
    property string streamHealthUrl: ""
    property string streamHealthText: ""
    property string streamHealthState: "idle"
    property int streamHealthPolls: 0
    // Playback metrics. Timestamps are epoch ms, 0 meaning "not reached yet".
    // These exist to answer one question before any further tuning: is the
    // constraint time-to-first-frame, or is it rebuffering once running?
    property double metricPlayClickMs: 0
    property double metricEngineReadyMs: 0
    property double metricMpvLaunchMs: 0
    property double metricFirstFrameMs: 0
    property int metricRebuffers: 0
    // Bounds the fast startup polling. mpv stays open on a stream that never
    // decodes (--idle=yes --keep-open=yes), so without a ceiling a dead
    // torrent would spawn a bridge process every 300ms forever.
    property int metricStartupPolls: 0
    property double metricRebufferMs: 0
    property double metricStarvedSinceMs: 0
    // Seconds of contiguous media ahead of the playhead, straight from mpv.
    property real bufferAheadSecs: 0
    property real cacheSpeedBps: 0
    // Prefetch state. prefetchLink is the stream whose engine we have already
    // asked the server to start; prefetchState says how far that has got, so
    // Play can skip the warm, adopt one in flight, or fall back to warming.
    property string prefetchLink: ""
    // idle | warming | ready | cold. "cold" means the warm completed but the
    // swarm produced no bytes in time, which is exactly when Play still needs
    // the full warm-and-launch rather than the shortcut.
    // Whether the last warm managed to read the file's tail. False does not
    // mean broken - it usually means "not downloaded yet" - but a stream that
    // also never produces a frame is waiting on its seek index, and saying so
    // beats a black screen under a reassuring "86% cached".
    property bool warmTailReady: true
    property string prefetchState: "idle"
    property int prefetchGen: 0
    property string pendingWarmLink: ""
    property var releaseQueue: []
    property string mpvSocketPath: ""
    property string playbackProvider: ""
    property string playbackId: ""
    property string playbackTitle: ""
    property var playbackSeasons: []
    property int playbackSeason: 0
    property int playbackEpisode: 0
    property int playbackInitialMaxEp: 0
    property string playbackCover: ""
    property int playbackStype: 1
    property real playbackPosition: 0
    property real playbackDuration: 0
    property double lastWatchSaveMs: 0
    property var activeStream: null
    property var nextEpisodeCandidate: null
    property int nextEpisodeSeason: 0
    property int nextEpisodeNumber: 0
    property bool nextEpisodeQueued: false
    property bool nextEpisodeWarmed: false
    property bool nextEpisodeTransitioned: false
    property bool nextEpisodeCancelled: false
    property int nextEpisodeCountdown: 0
    property int mpvPlaylistPosition: -1
    property string upNextText: ""
    property string mpvCommandPurpose: ""
    property var mpvCommandContext: null
    property var mpvPendingSubtitle: null
    property bool homeLoading: false
    property bool homeAppending: false
    property string homeProvider: ""
    property int suggestGen: 0
    property int searchGen: 0
    property int detailGen: 0
    property int resourceGen: 0
    property string playerUrl: ""
    property string playerTitle: ""
    property bool embeddedPlaying: false
    property bool playerFullscreen: false
    property int genreGen: 0
    property var genreCache: ({}) // genre -> items array, fast second-click
    property var genreCacheTime: ({}) // genre -> timestamp ms
    property string discoveryType: "all"
    property string discoverySort: "popular"
    property string discoveryGenre: ""
    property string discoveryYear: ""
    property string discoveryCatalogKey: ""
    property var discoveryCatalogs: []
    property int discoveryPage: 1
    property bool discoveryHasMore: false
    property var watchEntries: []
    property var libraryEntries: []
    property bool libraryBusy: false
    property string libraryTab: "movie"
    property string libraryQuery: ""
    property string librarySort: "recent"
    property string currentCover: ""
    property string detailsReturnView: "home"


    readonly property bool isSeries: root.details ? (root.details.subjectType === 2 || root.seasons.length > 0) : false
    readonly property bool currentInLibrary: root.libraryContains(root.currentProvider, root.currentId)
    property bool streamsBusy: false
    property int streamsGen: 0
    property bool addonManagerOpen: false
    property bool addonBusy: false
    property string addonMessage: ""
    property int addonGen: 0
    property bool tmdbConfigured: false
    property bool tmdbBusy: false
    property string tmdbMessage: ""
    property int tmdbGen: 0
    property var tmdbCast: []
    property var tmdbCrew: []
    property var tmdbEpisodes: []
    // Audience reviews. TMDB is sparse here - most titles have none and few
    // have more than three - so this is a modal you open, not a rail that
    // takes space on every page.
    property var tmdbReviews: []
    property bool reviewsOpen: false
    property var reviewsExpanded: ({})

    function toggleReviewExpanded(key) {
        var next = {};
        for (var k in root.reviewsExpanded) next[k] = root.reviewsExpanded[k];
        next[key] = !next[key];
        root.reviewsExpanded = next;
    }
    property var tmdbRecommendations: []
    property var tmdbTrailers: []
    property string tmdbImdbId: ""
    // The spotlight cycles through several trending titles; heroItem is
    // whichever slide is currently showing.
    property var heroItems: []
    property int heroIndex: 0
    property bool heroHovered: false
    readonly property var heroItem: (root.heroItems.length > 0 && root.heroIndex >= 0 && root.heroIndex < root.heroItems.length)
                                  ? root.heroItems[root.heroIndex] : null
    property bool cinematicHomeLoading: false
    property bool cinematicHomeLoaded: false
    property string currentBackdrop: ""
    property string currentLogo: ""
    property bool streamPickerOpen: false
    property int streamQualityLimit: 1080
    property real streamSizeLimit: 0
    property string streamSortMode: "balanced"



    // ---- settings -----------------------------------------------------------
    // Mirrors the bridge schema; defaults here match the backend so the UI is
    // correct on the very first frame, before settings_get returns.
    property var settings: ({
        backdropOpacity: 0.18,
        backdropDim: 0.70,
        heroOverlay: 0.16,
        spotlightRotate: true,
        spotlightSeconds: 7,
        railHoverPreview: true,
        themeSongs: true,
        themeVolume: 45,
        themeVideo: true,
        themeVideoDelay: 1.8,
        uiFontFamily: "Adwaita Sans",
        reviewOpacity: 0.94,
        prefetchStreams: true,
        cachePostersMB: 200,
        cacheThemesMB: 800,
        cacheTorrentGB: 11,
        cinematicMode: false
    })
    property var cacheUsage: []
    property bool cacheBusy: false

    function loadCacheUsage() {
        request("cache_usage", {}, function(resp) {
            if (resp && resp.ok && Array.isArray(resp.caches)) root.cacheUsage = resp.caches;
        });
    }

    function clearCache(name) {
        root.cacheBusy = true;
        request("cache_clear", { name: name }, function(resp) {
            root.cacheBusy = false;
            if (resp && resp.ok)
                root.statusText = "Cleared " + name + " \u2014 freed "
                                + root.fmtBytes(Number(resp.freed) || 0);
            else
                root.statusText = root.friendlyText((resp && resp.error) || "Could not clear that cache");
            root.loadCacheUsage();
        });
    }

    function fmtBytes(value) {
        var n = Number(value) || 0;
        if (n >= 1073741824) return (n / 1073741824).toFixed(1) + " GB";
        if (n >= 1048576) return (n / 1048576).toFixed(0) + " MB";
        if (n >= 1024) return (n / 1024).toFixed(0) + " KB";
        return n + " B";
    }
    property string settingsSection: "addons"     // addons | interface
    property bool settingsBusy: false

    function loadSettings() {
        request("settings_get", {}, function(resp) {
            if (resp && resp.ok && resp.settings) root.settings = resp.settings;
        });
    }

    function updateSetting(name, value) {
        // Optimistic: apply locally so sliders feel immediate, then persist.
        var next = {};
        for (var key in root.settings) next[key] = root.settings[key];
        next[name] = value;
        root.settings = next;
        root.settingsBusy = true;
        var payload = {};
        payload[name] = value;
        request("settings_set", { values: payload }, function(resp) {
            root.settingsBusy = false;
            if (resp && resp.ok && resp.settings) root.settings = resp.settings;
            else root.statusText = root.friendlyText((resp && resp.error) || "Could not save that setting");
        });
    }

    function resetSettings() {
        root.settingsBusy = true;
        request("settings_reset", {}, function(resp) {
            root.settingsBusy = false;
            if (resp && resp.ok && resp.settings) {
                root.settings = resp.settings;
                root.statusText = "Interface settings restored to defaults";
            }
        });
    }

    function loadAddons() {
        root.addonGen++;
        var gen = root.addonGen;
        request("addons", {}, function(resp) {
            if (gen !== root.addonGen) return;
            addonModel.clear();
            var items = (resp && resp.ok && Array.isArray(resp.addons)) ? resp.addons : [];
            for (var i = 0; i < items.length; i++) {
                var addon = items[i];
                addonModel.append({
                    addonName: root.friendlyText(addon.name || "Addon"),
                    addonHost: root.sanitize(addon.host || ""),
                    manifestUrl: String(addon.manifestUrl || ""),
                    addonEnabled: addon.enabled !== false,
                    addonAvailable: addon.available === true,
                    addonResources: Array.isArray(addon.resources) ? addon.resources.join(", ") : ""
                });
            }
            resolverModel.clear();
            var resolvers = (resp && resp.ok && Array.isArray(resp.resolvers)) ? resp.resolvers : [];
            for (var j = 0; j < resolvers.length; j++) {
                var resolver = resolvers[j];
                resolverModel.append({
                    resolverName: root.friendlyText(resolver.name || "Resolver"),
                    resolverHost: root.sanitize(resolver.host || ""),
                    resolverUrl: String(resolver.resolverUrl || ""),
                    resolverEnabled: resolver.enabled !== false,
                    resolverAvailable: resolver.available === true,
                    resolverBuiltin: resolver.builtin === true,
                    resolverMappings: Number(resolver.mappingCount || 0)
                });
            }
        });
        root.loadTmdbStatus();
        root.loadMdbStatus();
        root.loadSettings();
    }

    // ---- MDbList (optional): Rotten Tomatoes + Metacritic -----------------------
    property bool mdbConfigured: false
    property bool mdbBusy: false
    property string mdbMessage: ""
    property var mdbRatings: null

    function loadMdbStatus() {
        request("mdblist_status", {}, function(resp) {
            var was = root.mdbConfigured;
            root.mdbConfigured = resp && resp.ok && resp.configured === true;
            // Status is async and can arrive after a title is already open;
            // fetch that title's ratings rather than waiting for the next one.
            if (!was && root.mdbConfigured && root.view === "details" && root.currentId)
                root.loadMdbRatings();
        });
    }

    function saveMdbKey() {
        var key = mdbKeyField.text.trim();
        if (!key || root.mdbBusy || mdbSecretProc.running) return;
        root.mdbBusy = true;
        root.mdbMessage = "Validating MDbList key…";
        mdbSecretProc.pendingKey = key;
        mdbSecretProc.collected = "";
        mdbSecretProc.command = [root.bridge];
        mdbSecretProc.running = true;
    }

    function clearMdbKey() {
        root.mdbBusy = true;
        request("mdblist_clear", {}, function(resp) {
            root.mdbBusy = false;
            root.mdbConfigured = false;
            root.mdbRatings = null;
            root.mdbMessage = "MDbList disconnected";
        });
    }

    // Ratings are looked up per title once the IMDb id is known.
    function loadMdbRatings() {
        root.mdbRatings = null;
        if (!root.mdbConfigured || !root.currentId) return;
        // Guard on the title, not tmdbGen: loading a season bumps tmdbGen right
        // after enrich, which used to throw away every series lookup in flight.
        var wanted = root.currentId;
        request("mdblist_ratings", { id: wanted,
                                     mediaType: root.isSeries ? "series" : "movie" }, function(resp) {
            if (wanted !== root.currentId) return;
            root.mdbRatings = (resp && resp.ok && resp.found === true) ? resp : null;
        });
    }

    // The key travels over stdin so it never appears in the process list.
    Process {
        id: mdbSecretProc
        property string collected: ""
        property string pendingKey: ""
        stdinEnabled: true
        stdout: SplitParser { onRead: function(data) { mdbSecretProc.collected += data } }
        onStarted: {
            write(JSON.stringify({ cmd: "mdblist_configure", apiKey: pendingKey }) + "\n");
            pendingKey = "";
            mdbKeyField.clear();
        }
        onExited: function() {
            var resp = null;
            try { resp = JSON.parse(mdbSecretProc.collected); } catch (e) {}
            root.mdbBusy = false;
            root.mdbConfigured = resp && resp.ok && resp.configured === true;
            root.mdbMessage = root.mdbConfigured
                             ? "MDbList connected — Rotten Tomatoes and Metacritic enabled"
                             : root.friendlyText((resp && resp.error) || "Could not connect MDbList");
            if (root.mdbConfigured && root.details) root.loadMdbRatings();
        }
    }

    function loadTmdbStatus() {
        request("tmdb_status", {}, function(resp) {
            if (!resp || !resp.ok) return;
            root.tmdbConfigured = resp.configured === true;
            if (root.tmdbConfigured && root.view === "details" && root.details) root.loadTmdbDetails();
            if (root.tmdbConfigured && root.view === "home" && !root.cinematicHomeLoaded) root.loadCinematicHome(false);
        });
    }

    function saveTmdbToken() {
        var token = tmdbTokenField.text.trim();
        if (!token || root.tmdbBusy || tmdbSecretProc.running) return;
        root.tmdbBusy = true;
        root.tmdbMessage = "Validating TMDB access…";
        tmdbSecretProc.pendingToken = token;
        tmdbSecretProc.collected = "";
        tmdbSecretProc.command = [root.bridge];
        tmdbSecretProc.running = true;
    }

    function clearTmdbToken() {
        if (root.tmdbBusy) return;
        root.tmdbBusy = true;
        request("tmdb_clear", {}, function(resp) {
            root.tmdbBusy = false;
            root.tmdbConfigured = false;
            root.tmdbCast = [];
            root.tmdbCrew = [];
            root.tmdbEpisodes = [];
            root.tmdbRecommendations = [];
            detailRelatedModel.clear();
            root.tmdbTrailers = [];
        root.tmdbImdbId = "";
        root.mdbRatings = null;
            root.cinematicHomeLoaded = false;
            root.tmdbMessage = (resp && resp.ok) ? "TMDB disconnected" : ((resp && resp.error) || "Could not disconnect TMDB");
        });
    }

    function resetTmdbDetails() {
        root.tmdbGen++;
        root.tmdbCast = [];
        root.tmdbCrew = [];
        root.tmdbEpisodes = [];
        root.tmdbRecommendations = [];
        detailRelatedModel.clear();
        root.tmdbTrailers = [];
        root.tmdbReviews = [];
        root.reviewsOpen = false;
        root.reviewsExpanded = ({});
        root.currentBackdrop = "";
        root.currentLogo = "";
    }

    function loadTmdbDetails() {
        if (!root.tmdbConfigured || !root.currentId || !root.details) return;
        root.tmdbGen++;
        var gen = root.tmdbGen;
        request("tmdb_enrich", {
            id: root.currentId,
            mediaType: root.isSeries ? "series" : "movie",
            season: root.isSeries ? root.curSeason : 0
        }, function(resp) {
            if (gen !== root.tmdbGen || !resp || !resp.ok) return;
            root.tmdbCast = Array.isArray(resp.cast) ? resp.cast : [];
            root.cacheTmdbArtwork(root.tmdbCast, "image", function(v) { root.tmdbCast = v; });
            root.tmdbCrew = Array.isArray(resp.crew) ? resp.crew : [];
            root.tmdbEpisodes = Array.isArray(resp.episodes) ? resp.episodes : [];
            root.cacheTmdbArtwork(root.tmdbEpisodes, "still", function(v) { root.tmdbEpisodes = v; });
            root.tmdbRecommendations = Array.isArray(resp.recommendations) ? resp.recommendations : [];
            root.fillRelatedRail(root.tmdbRecommendations);
            root.tmdbTrailers = Array.isArray(resp.trailers) ? resp.trailers : [];
            root.tmdbReviews = Array.isArray(resp.reviews) ? resp.reviews : [];
            root.tmdbImdbId = root.sanitize(resp.imdbId || "");
            root.loadMdbRatings();
            root.setCachedImage(root.safeUrl(resp.backdrop || ""), function(v) { root.currentBackdrop = v; });
            root.setCachedImage(root.safeUrl(resp.logo || ""), function(v) { root.currentLogo = v; });
            if (resp.poster) root.setCachedImage(root.safeUrl(resp.poster), function(v) { detailPoster.source = v; });
            if (resp.overview && root.details && !(root.details.intro || root.details.description))
                root.details = Object.assign({}, root.details, { description: root.sanitize(resp.overview) });
        });
    }

    function loadTmdbSeason(season) {
        root.tmdbEpisodes = [];
        if (!root.tmdbConfigured || !root.currentId || !root.isSeries) return;
        root.tmdbGen++;
        var gen = root.tmdbGen;
        request("tmdb_season", { id: root.currentId, mediaType: "series", season: season }, function(resp) {
            if (gen !== root.tmdbGen || !resp || !resp.ok) return;
            root.tmdbEpisodes = Array.isArray(resp.episodes) ? resp.episodes : [];
            root.cacheTmdbArtwork(root.tmdbEpisodes, "still", function(v) { root.tmdbEpisodes = v; });
        });
    }

    function currentEpisodeInfo() {
        for (var i = 0; i < root.tmdbEpisodes.length; i++)
            if (Number(root.tmdbEpisodes[i].episode || 0) === Number(root.curEp)) return root.tmdbEpisodes[i];
        return null;
    }

    function seasonOptions() {
        var options = [];
        for (var i = 0; i < root.seasons.length; i++) {
            var number = Number(root.seasons[i].se || 0);
            if (number > 0) options.push({ value: String(number), label: "Season " + number });
        }
        return options;
    }

    function selectSeason(value) {
        var number = Number(value || 1);
        if (number === root.curSeason) return;
        root.curSeason = number;
        root.maxEp = root.episodeCount(number);
        root.curEp = 1;
        root.loadTmdbSeason(number);
        root.loadStreams(number, 1);
    }

    function addManifest() {
        var url = addonManifestField.text.trim();
        if (!url || root.addonBusy) return;
        root.addonBusy = true;
        root.addonMessage = "Validating manifest …";
        request("addon_add", { url: url }, function(resp) {
            root.addonBusy = false;
            if (!resp || !resp.ok || !resp.addon) {
                root.addonMessage = root.friendlyText((resp && resp.error) || "Could not add manifest");
                return;
            }
            root.addonMessage = "Added " + root.friendlyText(resp.addon.name || "addon");
            addonManifestField.clear();
            root.loadAddons();
        });
    }

    function toggleAddon(url, enabled) {
        if (!url || root.addonBusy) return;
        root.addonBusy = true;
        request("addon_toggle", { url: url, enabled: enabled }, function(resp) {
            root.addonBusy = false;
            root.addonMessage = (resp && resp.ok) ? (enabled ? "Addon enabled" : "Addon disabled") : root.friendlyText((resp && resp.error) || "Could not update addon");
            root.loadAddons();
        });
    }

    function removeAddon(url, name) {
        if (!url || root.addonBusy) return;
        root.addonBusy = true;
        request("addon_remove", { url: url }, function(resp) {
            root.addonBusy = false;
            root.addonMessage = (resp && resp.ok) ? ("Removed " + root.friendlyText(name || "addon")) : root.friendlyText((resp && resp.error) || "Could not remove addon");
            root.loadAddons();
        });
    }

    function addResolver() {
        var url = resolverManifestField.text.trim();
        if (!url || root.addonBusy) return;
        root.addonBusy = true;
        root.addonMessage = "Validating resolver …";
        request("resolver_add", { url: url }, function(resp) {
            root.addonBusy = false;
            if (!resp || !resp.ok || !resp.resolver) {
                root.addonMessage = root.friendlyText((resp && resp.error) || "Could not add resolver");
                return;
            }
            root.addonMessage = "Added resolver " + root.friendlyText(resp.resolver.name || "resolver");
            resolverManifestField.clear();
            root.loadAddons();
        });
    }

    function toggleResolver(url, enabled) {
        if (!url || root.addonBusy || url.indexOf("builtin:") === 0) return;
        root.addonBusy = true;
        request("resolver_toggle", { url: url, enabled: enabled }, function(resp) {
            root.addonBusy = false;
            root.addonMessage = (resp && resp.ok) ? (enabled ? "Resolver enabled" : "Resolver disabled") : root.friendlyText((resp && resp.error) || "Could not update resolver");
            root.loadAddons();
        });
    }

    function removeResolver(url, name) {
        if (!url || root.addonBusy || url.indexOf("builtin:") === 0) return;
        root.addonBusy = true;
        request("resolver_remove", { url: url }, function(resp) {
            root.addonBusy = false;
            root.addonMessage = (resp && resp.ok) ? ("Removed " + root.friendlyText(name || "resolver")) : root.friendlyText((resp && resp.error) || "Could not remove resolver");
            root.loadAddons();
        });
    }

    // ---------------- bridge IPC (single serialized process) ----------------
    property var pending: []
    property var cbChain: null

    // ---- persistent bridge -------------------------------------------------
    // A single long-lived python process serves every command over stdio.
    // Requests carry a reserved `_rid` so several can be in flight at once and
    // a slow stream scrape never blocks a poster fetch queued behind it.
    // If the daemon is unavailable the old one-shot spawn still works.
    // One outstanding telemetry request per channel. These replace the old
    // Process.running guards: the daemon answers several requests at once, so
    // "is the process busy" no longer describes whether a poll is in flight.
    property bool mpvStatusInFlight: false
    property bool streamStatusInFlight: false
    // Issue times, so a reply that never arrives cannot silence a channel for
    // good. Exit and error both clear the flag; a daemon wedged without
    // exiting clears neither, and telemetry would simply stop.
    property double mpvStatusSentMs: 0
    property double streamStatusSentMs: 0
    readonly property int telemetryStallMs: 5000
    // The stall escape above lets a second request go out while the first is
    // still outstanding, so a generation decides which reply still owns the
    // channel. Without it the slow first reply would clear the in-flight flag
    // its successor is relying on, and apply the older of two samples.
    property int mpvStatusGeneration: 0
    property int streamStatusGeneration: 0
    property var daemonCallbacks: ({})
    property int daemonSeq: 0
    property bool daemonReady: false
    property int daemonRetries: 0

    function request(cmd, params, cb) {
        params = params || {};
        if (!root.daemonReady) {
            root.requestOneShot(cmd, params, cb);
            return;
        }
        root.daemonSeq++;
        var rid = root.daemonSeq;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = cmd;
        req._rid = rid;
        root.daemonCallbacks[rid] = cb || null;
        try {
            daemonProc.write(JSON.stringify(req) + "\n");
        } catch (e) {
            delete root.daemonCallbacks[rid];
            root.daemonReady = false;
            root.requestOneShot(cmd, params, cb);
        }
    }

    function handleDaemonLine(line) {
        var resp = null;
        try { resp = JSON.parse(line); } catch (e) { return; }
        if (!resp) return;
        var rid = Number(resp._rid || 0);
        if (rid === 0) {
            // Control frame: ready handshake, or the bridge telling us its own
            // source changed and this process is now serving stale code.
            if (resp.ready === true) { root.daemonReady = true; root.daemonRetries = 0; }
            else if (resp.reload === true) root.daemonReady = false;
            return;
        }
        var cb = root.daemonCallbacks[rid];
        delete root.daemonCallbacks[rid];
        if (cb) cb(resp, 0);
    }

    function failPendingDaemonCallbacks() {
        var pendingIds = Object.keys(root.daemonCallbacks);
        for (var i = 0; i < pendingIds.length; i++) {
            var cb = root.daemonCallbacks[pendingIds[i]];
            delete root.daemonCallbacks[pendingIds[i]];
            if (cb) cb({ ok: false, error: "bridge restarted" }, 1);
        }
    }

    Process {
        id: daemonProc
        command: [root.bridge, "--daemon"]
        running: true
        stdinEnabled: true
        stdout: SplitParser { onRead: function(line) { root.handleDaemonLine(line); } }
        onExited: function(code) {
            root.daemonReady = false;
            root.failPendingDaemonCallbacks();
            // Restart a few times, then fall back to one-shot spawning rather
            // than looping forever on a broken bridge.
            if (root.daemonRetries < 5) {
                root.daemonRetries++;
                daemonRestartTimer.restart();
            }
        }
    }

    Timer {
        id: daemonRestartTimer
        interval: 400 * root.daemonRetries
        repeat: false
        onTriggered: daemonProc.running = true
    }

    // ---- one-shot fallback (original behaviour) ----------------------------
    function requestOneShot(cmd, params, cb) {
        params = params || {};
        if (bridgeProc.running) {
            root.pending.push({ cmd: cmd, params: params, cb: cb });
            return;
        }
        root._start(cmd, params, cb);
    }

    function _start(cmd, params, cb) {
        bridgeProc.collected = "";
        root.cbChain = cb;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = cmd;
        bridgeProc.command = [root.bridge, JSON.stringify(req)];
        bridgeProc.running = true;
    }

    Process {
        id: bridgeProc
        property string collected: ""
        stdout: SplitParser {
            onRead: function(data) { bridgeProc.collected += data }
        }
        onExited: function(code, status) {
            var cb = root.cbChain;
            root.cbChain = null;
            var resp = null;
            try { resp = JSON.parse(bridgeProc.collected); } catch (e) {}
            if (cb) cb(resp, code);
            if (root.pending.length > 0) {
                var next = root.pending.shift();
                root._start(next.cmd, next.params, next.cb);
            }
        }
    }

    // Credentials travel over stdin so they are not exposed in the process list.
    Process {
        id: tmdbSecretProc
        property string collected: ""
        property string pendingToken: ""
        stdinEnabled: true
        stdout: SplitParser { onRead: function(data) { tmdbSecretProc.collected += data } }
        onStarted: {
            write(JSON.stringify({ cmd: "tmdb_configure", readAccessToken: pendingToken }) + "\n");
            pendingToken = "";
            tmdbTokenField.clear();
        }
        onExited: function() {
            var resp = null;
            try { resp = JSON.parse(tmdbSecretProc.collected); } catch (e) {}
            root.tmdbBusy = false;
            root.tmdbConfigured = resp && resp.ok && resp.configured === true;
            root.tmdbMessage = root.tmdbConfigured
                             ? "TMDB connected — OmaCine discovery and rich metadata enabled"
                             : root.friendlyText((resp && resp.error) || "Could not connect TMDB");
            if (root.tmdbConfigured && root.view === "details" && root.details) root.loadTmdbDetails();
            if (root.tmdbConfigured) root.loadCinematicHome(true);
        }
    }

    // dedicated streams process — bypasses main queue so E1 loads instantly even when details pending
    Process {
        id: streamsProc
        property string collected: ""
        property var pendingCb: null
        stdout: SplitParser { onRead: function(data) { streamsProc.collected += data } }
        onExited: function(code, status) {
            var cb = streamsProc.pendingCb;
            streamsProc.pendingCb = null;
            var resp = null;
            try { resp = JSON.parse(streamsProc.collected); } catch (e) {}
            if (cb) cb(resp, code);
        }
    }
    // Warm the stream list for a hovered title so opening it is instant. Stream
    // scrapes are expensive, so this only runs on the multiplexed daemon, only
    // once per title, and only while nothing else is scraping.
    property var prefetchedStreams: ({})
    property bool streamPrefetchInFlight: false

    function prefetchStreams(item) {
        if (!root.daemonReady || !item || root.streamPrefetchInFlight) return;
        if (String(item.provider || "") !== "stremio") return;
        var id = String(item.id || "");
        if (!id) return;
        var series = Number(item.stype || 1) === 2;
        var season = series ? 1 : 0;
        var episode = series ? 1 : 0;
        var key = id + "|" + season + "|" + episode;
        if (root.prefetchedStreams[key]) return;
        root.prefetchedStreams[key] = true;
        root.streamPrefetchInFlight = true;
        root.request("resources", { id: id, provider: "stremio", season: season, episode: episode },
                     function() { root.streamPrefetchInFlight = false; });
    }

    function requestStreams(params, cb) {
        // if streams proc busy, queue via main request to avoid overlap — rare
        if (streamsProc.running) {
            request("resources", params, cb);
            return;
        }
        streamsProc.collected = "";
        streamsProc.pendingCb = cb;
        var req = JSON.parse(JSON.stringify(params));
        req.cmd = "resources";
        streamsProc.command = [root.bridge, JSON.stringify(req)];
        streamsProc.running = true;
    }

    // ---------------- helpers ----------------
    function fmtSize(s) {
        var n = parseInt(s || "0", 10);
        if (n > 1073741824) return (n / 1073741824).toFixed(1) + " GB";
        if (n > 1048576) return (n / 1048576).toFixed(0) + " MB";
        return n + " B";
    }
    function fmtDur(s) {
        s = Math.floor(s || 0);
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
        if (h > 0) return h + "h " + String(m).padStart(2, "0") + "m";
        return m + "m";
    }
    function fmtRate(value) {
        var n = Number(value || 0);
        if (n >= 1048576) return (n / 1048576).toFixed(n >= 10485760 ? 0 : 1) + " MB/s";
        if (n >= 1024) return (n / 1024).toFixed(0) + " KB/s";
        return n > 0 ? Math.round(n) + " B/s" : "";
    }
    function cachedPercent(value) {
        var n = Math.max(0, Math.min(1, Number(value || 0))) * 100;
        if (n <= 0) return "";
        if (n < 0.1) return "<0.1% cached";
        return n.toFixed(n < 10 ? 1 : 0) + "% cached";
    }
    function coverUrlOf(obj) {
        if (!obj) return "";
        var c = obj.cover;
        if (c && typeof c === "object") return root.safeUrl(c.url || "");
        if (typeof c === "string") return root.safeUrl(c);
        return "";
    }
    // Only http(s) URLs may reach Image.source (scraper-controlled data)
    function safeUrl(s) {
        s = String(s || "");
        if (s.indexOf("https://") === 0 || s.indexOf("http://") === 0) return s;
        return "";
    }

    // Artwork may be a remote URL or a file the bridge already cached on disk.
    // QML Image needs file:// for the latter, so image sources resolve through
    // here; safeUrl() stays http(s)-only because it also guards stream and
    // subtitle URLs handed to mpv.
    readonly property string posterCacheRoot: Quickshell.env("HOME") + "/.cache/omamovie/"
    readonly property string altPosterCacheRoot: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omamovie/"
    // OmaCine-local text scale. The shell's font size is a system-wide setting,
    // so Settings > Interface scales only this plugin's type. Every font size
    // in the panel and its components goes through fs().
    // Two families, on purpose. Monospace is a typesetting tool for columns of
    // data, not for language: it set every string the same width, which made
    // prose harder to read and truncated names that would otherwise fit
    // ("Rebecc\u2026", "The Whisper M\u2026"). Adwaita Sans is ~26% narrower for the
    // same text, so most of that truncation simply goes away.
    readonly property string uiFont: {
        var chosen = String(root.settings.uiFontFamily || "").trim();
        // Qt falls back silently on an unknown family, which reads as the
        // setting having done nothing. Only offer names Qt reports as present.
        if (chosen !== "" && Qt.fontFamilies().indexOf(chosen) >= 0) return chosen;
        return Qt.fontFamilies().indexOf("Adwaita Sans") >= 0 ? "Adwaita Sans" : Style.font.family;
    }

    // Curated candidates, intersected with what is installed. Monospace is on
    // the list deliberately: it is a legitimate taste, not a wrong answer.
    function fontOptions() {
        var wanted = ["Adwaita Sans", "Inter", "Noto Sans", "Carlito",
                      "DejaVu Sans", "Liberation Sans", Style.font.family];
        var have = Qt.fontFamilies();
        var out = [];
        for (var i = 0; i < wanted.length; i++) {
            var name = wanted[i];
            if (!name) continue;
            var seen = false;
            for (var j = 0; j < out.length; j++) if (out[j].value === name) seen = true;
            if (!seen && have.indexOf(name) >= 0)
                out.push({ value: name,
                           label: name === Style.font.family ? name + "  (monospace)" : name });
        }
        return out;
    }
    // Kept for strings where character alignment genuinely helps: stream specs,
    // rating figures, anything read as a column rather than as a sentence.
    readonly property string dataFont: Style.font.family

    readonly property real textScale: {
        var value = Number(root.settings.textScale);
        return isNaN(value) || value <= 0 ? 1.0 : value;
    }
    function fs(size) {
        var base = Number(size);
        return Math.max(1, Math.round((isNaN(base) ? 10 : base) * root.textScale));
    }

    function imageSource(value) {
        var s = String(value || "");
        if (s.indexOf("https://") === 0 || s.indexOf("http://") === 0 || s.indexOf("file://") === 0) return s;
        if (s.indexOf("..") !== -1) return "";
        if (s.indexOf(root.posterCacheRoot) === 0 || s.indexOf(root.altPosterCacheRoot) === 0) return "file://" + s;
        return "";
    }
    function episodeCount(se) {
        for (var i = 0; i < root.seasons.length; i++)
            if (Number(root.seasons[i].se) === Number(se)) return Number(root.seasons[i].maxEp) || 0;
        if (root.details && root.details.resourceDetectors && root.details.resourceDetectors.length > 0) {
            var d = root.details.resourceDetectors[0];
            return Number(d.totalEpisode) || 1;
        }
        return 1;
    }

    function audioId(option) {
        if (!option) return "";
        return root.sanitize(option.subjectId || option.id || "");
    }
    function audioName(option) {
        if (!option) return "Audio";
        if (option.original === true) return "Original";
        var label = root.sanitize(option.lanName || option.audioName || option.language || option.name || "Audio");
        var code = String(option.lanCode || "").toLowerCase();
        if (code === "ptbr") return "Portuguese (BR)";
        if (code === "esla") return "Spanish (LA)";
        label = label.replace(/\s+dub\s*$/i, "");
        return label || "Audio";
    }
    function audioOptionsOf(value) {
        var source = (value && Array.isArray(value.dubs)) ? value.dubs : [];
        var out = [];
        for (var i = 0; i < source.length; i++) {
            if (root.audioId(source[i])) out.push(source[i]);
        }
        return out;
    }
    function audioIndexForId(options, id) {
        for (var i = 0; i < options.length; i++) {
            if (root.audioId(options[i]) === String(id || "")) return i;
        }
        return -1;
    }
    function preferredAudioIndex(options) {
        for (var i = 0; i < options.length; i++) {
            var label = root.audioName(options[i]).toLowerCase();
            if (options[i].original === true || label === "original" || label.indexOf("original") >= 0) return i;
        }
        for (var j = 0; j < options.length; j++) {
            var english = root.audioName(options[j]).toLowerCase();
            if (english === "english" || english.indexOf("english") >= 0) return j;
        }
        return options.length ? 0 : -1;
    }
    function currentAudioName() {
        if (root.selectedAudio >= 0 && root.selectedAudio < root.audioOptions.length)
            return root.audioName(root.audioOptions[root.selectedAudio]);
        return "selected audio";
    }

    // ---------------- actions ----------------
    // Swap remote cover URLs for local cached poster files (fast repeat loads)
    // Resolve artwork through the on-disk cache before falling back to the
    // network. The details poster and backdrop used to be assigned the remote
    // URL directly, so reopening a saved title re-downloaded both every time.
    function setCachedImage(url, apply) {
        var direct = root.imageSource(url);
        if (!direct) { apply(""); return; }
        request("posters", { urls: [url] }, function(resp) {
            var cached = (resp && resp.ok && resp.paths) ? resp.paths[url] : "";
            apply(cached ? root.imageSource(cached) : direct);
        });
    }

    // Cast portraits and episode stills were the last artwork still fetched
    // straight from the network by Qt's image loader, which is where the
    // HTTP/2 errors against image.tmdb.org show up. Pull them onto disk the
    // same way posters and backdrops are, then re-point the list at the files.
    function cacheTmdbArtwork(items, field, assign) {
        var list = items || [];
        var urls = [];
        for (var i = 0; i < list.length; i++) {
            var url = list[i] ? String(list[i][field] || "") : "";
            if (url.indexOf("http") === 0 && urls.indexOf(url) === -1) urls.push(url);
        }
        if (urls.length === 0) return;
        request("posters", { urls: urls }, function(resp) {
            if (!resp || !resp.ok || !resp.paths) return;
            var patched = [];
            var changed = false;
            for (var k = 0; k < list.length; k++) {
                var item = list[k];
                var cached = item ? resp.paths[String(item[field] || "")] : "";
                if (!cached) { patched.push(item); continue; }
                var copy = {};
                for (var key in item) copy[key] = item[key];
                copy[field] = cached;
                patched.push(copy);
                changed = true;
            }
            if (changed) assign(patched);
        });
    }

    function cachePosters(model) {
        root.cachePostersFor([model]);
    }

    // One round trip for every rail on screen. Separate calls per model used to
    // queue behind each other on the shared bridge process and re-run the
    // poster-cache sweep once per call.
    function cachePostersFor(models) {
        var wanted = [];
        var seen = {};
        var targets = [];
        for (var m = 0; m < models.length; m++) {
            var model = models[m];
            if (!model || model.count === 0) continue;
            targets.push(model);
            for (var i = 0; i < model.count; i++) {
                var url = model.get(i).cover;
                if (url && !seen[url]) { seen[url] = 1; wanted.push(url); }
            }
        }
        if (wanted.length === 0 || targets.length === 0) return;
        request("posters", { urls: wanted }, function(resp) {
            if (!resp || !resp.ok || !resp.paths) return;
            var paths = resp.paths;
            for (var t = 0; t < targets.length; t++) {
                var target = targets[t];
                for (var k = 0; k < target.count; k++) {
                    var cached = paths[target.get(k).cover];
                    if (cached && target.get(k).coverPath !== cached) target.set(k, { coverPath: cached });
                }
            }
        });
    }
    // Open a performer's filmography in the results grid. TMDB ids are opaque
    // numbers, so the grid is populated from the credits rather than a search.
    function openPerson(personId, personName) {
        var id = String(personId || "");
        if (!id || !root.tmdbConfigured) return;
        root.busy = true;
        root.busyLabel = "Loading " + (personName || "credits") + " …";
        root.searchGen++;
        root.genreGen++;
        var gen = root.searchGen;
        request("tmdb_person", { id: id }, function(resp) {
            if (gen !== root.searchGen) return;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = root.friendlyText((resp && resp.error) || "Could not load this performer");
                return;
            }
            var works = Array.isArray(resp.works) ? resp.works : [];
            root.results = works;
            resultModel.clear();
            for (var i = 0; i < works.length; i++)
                root.appendHomeItem(resultModel, works[i], "stremio");
            root.view = "grid";
            root.statusText = works.length
                            ? root.sanitize(resp.name || personName || "Performer") + " • " + works.length + " titles"
                            : "No credits available for " + root.sanitize(resp.name || personName || "this performer");
            root.cachePosters(resultModel);
        });
    }

    function doSearch() {
        var q = searchField.text.trim();
        if (!q) return;
        suggestTimer.stop();
        root.suggestGen++;
        suggestionModel.clear();
        root.query = q;
        root.busy = true;
        root.busyLabel = "Searching \u2026";
        root.statusText = "";
        root.searchGen++;
        root.genreGen++; // cancel any pending genre fetch
        var gen = root.searchGen;
        var searchProvider = root.provider;
        request("search", { q: q, page: 1, provider: searchProvider }, function(resp, code) {
            if (gen !== root.searchGen) return;
            if (searchProvider !== root.provider) return;
            root.busy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Search failed";
                return;
            }
            root.results = resp.items || [];
            resultModel.clear();
            for (var i = 0; i < root.results.length; i++) {
                var r = root.results[i];
                resultModel.append({ id: root.sanitize(r.id), title: root.sanitize(r.title), year: root.sanitize(r.year || ""), rating: root.sanitize(r.rating !== null ? String(r.rating) : "-"), cover: root.sanitize(r.cover || ""), coverPath: root.sanitize(r.cover || ""), duration: root.sanitize(r.duration || ""), stype: root.sanitize(r.stype || ""), provider: root.sanitize(r.provider || searchProvider) });
            }
            root.view = "grid";
            root.statusText = resultModel.count + " results for \u201C" + q + "\u201D";
            root.cachePosters(resultModel);
        });
    }

    function debounceSuggest() {
        if (searchField.text.trim().length < 2) {
            suggestTimer.stop();
            root.suggestGen++;
            suggestionModel.clear();
            return;
        }
        suggestTimer.restart();
    }

    function finishDetails(raw, gen, fallbackAudio, wantedSeason, wantedEpisode) {
        if (gen !== root.detailGen) return;
        root.busy = false;
        root.details = root.sanitizeDetails(raw);
        var options = root.audioOptionsOf(raw);
        root.audioOptions = options.length ? options : (fallbackAudio || []);
        root.selectedAudio = root.audioIndexForId(root.audioOptions, root.currentId);
        if (root.details && root.details.title) root.currentTitle = root.sanitize(root.details.title);
        var ss = (raw && raw.seasons && raw.seasons.seasons) || [];
        root.seasons = ss.length ? ss : [];
        root.curSeason = wantedSeason || 1;
        var seasonExists = false;
        for (var i = 0; i < root.seasons.length; i++) {
            if (Number(root.seasons[i].se) === Number(root.curSeason)) { seasonExists = true; break; }
        }
        if (root.seasons.length && !seasonExists) root.curSeason = Number(root.seasons[0].se) || 1;
        root.maxEp = root.episodeCount(root.curSeason);
        root.curEp = root.isSeries ? Math.min(Math.max(wantedEpisode || 1, 1), root.maxEp) : 0;
        root.streams = [];
        root.selStream = -1;
        root.subs = [];
        root.captionsGen++;
        root.captionsBusy = false;
        root.selectedSubtitle = "auto";
        root.statusText = root.isSeries ? "Pick a season and episode" : "Pick a stream and press Play";
        root.loadStreams(root.isSeries ? root.curSeason : 0, root.isSeries ? root.curEp : 0);
        root.loadTmdbDetails();
        var cover = root.coverUrlOf(root.details);
        if (cover) root.setCachedImage(root.safeUrl(cover), function(v) { detailPoster.source = v; });
    }

    function openItem(it) {
        if (!it) return;
        // ListModel.get() hands back a live reference into the model. Opening a
        // card from the "More Like This" rail clears that very model further
        // down (resetTmdbDetails), which would blank these fields mid-flight.
        // Snapshot everything needed before touching any model.
        var picked = {
            id: root.sanitize(it.id),
            title: root.sanitize(it.title),
            cover: root.safeUrl(it.cover || it.coverPath || ""),
            provider: root.sanitize(it.provider || root.provider),
            season: Number(it.resumeSeason || 1),
            episode: Number(it.resumeEpisode || 1)
        };
        if (!picked.id) { root.statusText = "That title has no id to open"; return; }
        // Opening a related title from the details page must not make "details"
        // the place Back returns to — keep the surface we originally came from.
        if (root.view !== "details") root.detailsReturnView = root.view;
        root.currentId = picked.id;
        root.currentTitle = picked.title;
        root.currentCover = picked.cover;
        root.currentProvider = picked.provider;
        var wantedSeason = picked.season;
        var wantedEpisode = picked.episode;
        root.details = null;
        root.seasons = [];
        root.streams = [];
        root.selStream = -1;
        root.subs = [];
        root.captionsGen++;
        root.captionsBusy = false;
        root.selectedSubtitle = "auto";
        root.audioOptions = [];
        root.selectedAudio = -1;
        root.audioExplicit = false;
        root.resetTmdbDetails();
        root.setCachedImage(picked.cover, function(v) { detailPoster.source = v; });
        root.view = "details";
        root.themeEditOpen = false;
        root.themeEditText = "";
        root.themeEditNote = "";
        root.startThemeFor(picked.id);
        root.statusText = "Loading \u201C" + picked.title + "\u201D \u2026";
        root.busy = true;
        root.busyLabel = "Loading details \u2026";
        root.detailGen++;
        root.resourceGen++;
        var gen = root.detailGen;
        request("details", { id: picked.id, provider: root.currentProvider }, function(resp) {
            if (gen !== root.detailGen) return;
            if (!resp || !resp.ok) {
                root.busy = false;
                root.statusText = (resp && resp.error) || "Details failed";
                return;
            }
            var options = root.audioOptionsOf(resp.value);
            var preferred = root.preferredAudioIndex(options);
            var preferredId = preferred >= 0 ? root.audioId(options[preferred]) : "";
            if (preferredId && preferredId !== root.currentId) {
                root.currentId = preferredId;
                root.statusText = "Switching to " + root.audioName(options[preferred]) + " audio \u2026";
                request("details", { id: preferredId, provider: root.currentProvider }, function(originalResp) {
                    if (gen !== root.detailGen) return;
                    if (originalResp && originalResp.ok) {
                        root.finishDetails(originalResp.value, gen, options, wantedSeason, wantedEpisode);
                    } else {
                        root.currentId = picked.id;
                        root.finishDetails(resp.value, gen, options, wantedSeason, wantedEpisode);
                    }
                });
            } else {
                root.finishDetails(resp.value, gen, options, wantedSeason, wantedEpisode);
            }
        });
    }

    function openDetails(idx) {
        if (idx < 0 || idx >= resultModel.count) return;
        root.openItem(resultModel.get(idx));
    }

    function openHomeDetails(idx) {
        if (idx < 0 || idx >= homeModel.count) return;
        root.openItem(homeModel.get(idx));
    }

    function selectAudio(idx) {
        if (idx < 0 || idx >= root.audioOptions.length || root.busy) return;
        var option = root.audioOptions[idx];
        var nextId = root.audioId(option);
        if (!nextId) return;
        if (nextId === root.currentId) {
            root.selectedAudio = idx;
            return;
        }
        var previousId = root.currentId;
        var previousIndex = root.selectedAudio;
        var previousAudioExplicit = root.audioExplicit;
        var preservedOptions = root.audioOptions;
        var wantedSeason = root.curSeason;
        var wantedEpisode = root.curEp;
        root.busy = true;
        root.busyLabel = "Switching audio \u2026";
        root.statusText = "Switching to " + root.audioName(option) + " audio \u2026";
        root.detailGen++;
        root.resourceGen++;
        root.streamsGen++;
        var gen = root.detailGen;
        root.currentId = nextId;
        root.selectedAudio = idx;
        root.audioExplicit = true;
        request("details", { id: nextId, provider: root.currentProvider }, function(resp) {
            if (gen !== root.detailGen) return;
            if (!resp || !resp.ok) {
                root.currentId = previousId;
                root.selectedAudio = previousIndex;
                root.audioExplicit = previousAudioExplicit;
                root.busy = false;
                root.statusText = (resp && resp.error) || "Could not switch audio";
                return;
            }
            root.finishDetails(resp.value, gen, preservedOptions, wantedSeason, wantedEpisode);
        });
    }

    function loadStreams(se, ep) {
        root.busy = true;
        root.streamsBusy = true;
        root.busyLabel = "Loading streams \u2026";
        root.resourceGen++;
        root.streamsGen++;
        var gen = root.resourceGen;
        var sgen = root.streamsGen;
        // status placeholder handled via streamsBusy + streams length in UI
        if (root.isSeries) root.statusText = "Loading streams for S" + se + "E" + (ep || 1) + " \u2026";
        else root.statusText = "Loading streams \u2026";
        var params = { id: root.currentId, season: se, episode: ep, perPage: 20, allowDub: root.audioExplicit, provider: root.currentProvider };
        var cb = function(resp, code) {
            if (gen !== root.resourceGen || sgen !== root.streamsGen) return;
            root.busy = false;
            root.streamsBusy = false;
            var items = (resp && resp.ok && resp.items) ? resp.items : [];
            root.streams = root.sanitizeStreams(items);
            root.selStream = -1;
            root.streamPickerOpen = false;
            if (root.streams.length === 0) {
                if (root.currentProvider === "stremio")
                    root.statusText = "No streams from enabled sources — open Sources to review them";
                else if (root.isSeries)
                    root.statusText = root.currentProvider === "stremio"
                                      ? ("No 4KHDHub releases for S" + se + "E" + (ep || 1) + " — retry or use MovieBox")
                                      : ("No streams in " + root.currentAudioName() + " for S" + se + "E" + (ep || 1) + " — choose another audio or retry");
                else
                    root.statusText = root.currentProvider === "stremio"
                                      ? "No 4KHDHub releases — retry or use MovieBox"
                                      : ("No streams in " + root.currentAudioName() + " — choose another audio or retry");
            } else {
                if (root.isSeries) root.statusText = root.streams.length + " streams for S" + se + "E" + (ep || 1) + " — pick one and press Play";
                else root.statusText = root.streams.length + " streams — pick one and press Play";
                root.selectPreferredStream();
            }
        };
        // use dedicated proc for instant E1 load without blocking on details queue
        root.requestStreams(params, cb);
    }

    function selectStream(i) {
        root.selStream = i;
        if (i >= 0 && i < root.streams.length) root.loadCaptions(root.streams[i]);
    }

    function streamMatchesPreferences(stream) {
        if (!stream) return false;
        var resolution = Number(stream.resolution || 0);
        var size = Number(stream.size || 0);
        if (root.streamQualityLimit > 0 && resolution > root.streamQualityLimit) return false;
        if (root.streamSizeLimit > 0 && size > root.streamSizeLimit) return false;
        return true;
    }

    function selectPreferredStream() {
        if (!root.streams.length) { root.selStream = -1; return; }
        for (var i = 0; i < root.streams.length; i++) {
            if (root.streamMatchesPreferences(root.streams[i])) {
                root.selectStream(i);
                return;
            }
        }
        root.selectStream(0);
    }

    function setStreamQualityLimit(value) {
        root.streamQualityLimit = Number(value || 0);
        if (!root.streamMatchesPreferences(root.streams[root.selStream])) root.selectPreferredStream();
    }

    function setStreamSizeLimit(value) {
        root.streamSizeLimit = Number(value || 0);
        if (!root.streamMatchesPreferences(root.streams[root.selStream])) root.selectPreferredStream();
    }

    function normalizeSubtitles(items) {
        var out = [];
        var seen = {};
        if (!Array.isArray(items)) return out;
        for (var i = 0; i < items.length && out.length < 40; i++) {
            var url = root.safeUrl(items[i] && items[i].url || "");
            if (!url || seen[url]) continue;
            seen[url] = true;
            var name = root.friendlyText(items[i].name || items[i].lang || items[i].language || "Subtitle");
            var source = root.friendlyText(items[i].source || "");
            out.push({ name: name + (source ? (" • " + source) : ""), url: url });
        }
        return out;
    }

    function mergeSubtitles(first, second) {
        return root.normalizeSubtitles((Array.isArray(first) ? first : []).concat(Array.isArray(second) ? second : []));
    }

    function subtitleOptions() {
        if (root.captionsBusy && root.subs.length === 0)
            return [{ value: "auto", label: "Loading captions…" }, { value: "off", label: "Captions off" }];
        if (root.subs.length === 0)
            return [{ value: "off", label: "No captions available" }];
        var options = [{ value: "auto", label: "Automatic captions" }, { value: "off", label: "Captions off" }];
        for (var i = 0; i < root.subs.length; i++)
            options.push({ value: root.subs[i].url, label: root.subs[i].name || ("Subtitle " + (i + 1)) });
        return options;
    }

    function loadCaptions(stream) {
        root.captionsGen++;
        var gen = root.captionsGen;
        root.captionsBusy = true;
        root.selectedSubtitle = "auto";
        root.subs = root.normalizeSubtitles(stream && stream.subtitles || []);
        request("captions", {
            id: root.currentId,
            rid: String(stream && stream.resourceId || ""),
            season: root.isSeries ? root.curSeason : 0,
            episode: root.isSeries ? root.curEp : 0,
            provider: root.currentProvider
        }, function(resp) {
            if (gen !== root.captionsGen) return;
            root.captionsBusy = false;
            var options = (resp && resp.ok && Array.isArray(resp.options)) ? resp.options : [];
            root.subs = root.mergeSubtitles(root.subs, options);
            if (root.subs.length === 0) root.selectedSubtitle = "off";
        });
    }

    function selectSubtitle(value) {
        var next = String(value || "off");
        if (next !== "off" && next !== "auto") {
            var allowed = false;
            for (var i = 0; i < root.subs.length; i++)
                if (root.subs[i].url === next) { allowed = true; break; }
            if (!allowed) return;
        }
        root.selectedSubtitle = next;
        if (!root.playing || root.playbackId !== root.currentId) return;
        if (next === "off") root.sendMpvCommands([["set", "sid", "no"]], "captions");
        else if (next === "auto") root.sendMpvCommands([["set", "sid", "auto"]], "captions");
        else root.sendMpvCommands([["sub-add", next, "select"]], "captions");
    }

    Process {
        id: prefetchProc
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ prefetchProc.collected += data } }
        onExited: function(code){ try{ JSON.parse(prefetchProc.collected);}catch(e){} }
    }
    Process {
        id: prefetchStreamsProc
        property string collected: ""
        property string sessionPath: ""
        stdout: SplitParser { onRead: function(data){ prefetchStreamsProc.collected += data } }
        onExited: function(code){
            var resp = null;
            try { resp = JSON.parse(prefetchStreamsProc.collected); } catch (e) {}
            if (prefetchStreamsProc.sessionPath === root.mpvSocketPath) root.handlePreparedEpisode(resp);
            else if (root.playing && root.mpvSocketPath) Qt.callLater(function(){ root.prepareNextEpisode(); });
        }
    }

    // Warm the details cache on hover. With the daemon this no longer has to
    // stand down whenever the bridge is busy — that gate meant prefetch almost
    // never fired on a freshly opened panel.
    function prefetchDetails(id, itemProvider) {
        if (!id) return;
        if (root.daemonReady) {
            root.request("details", { id: id, provider: itemProvider || root.provider }, null);
            return;
        }
        if (bridgeProc.running || root.pending.length > 0 || prefetchProc.running) return;
        var req = JSON.stringify({ cmd: "details", id: id, provider: itemProvider || root.provider });
        prefetchProc.collected = "";
        prefetchProc.command = [root.bridge, req];
        prefetchProc.running = true;
    }
    function nextEpisodeCoordinates(se, ep) {
        var count = root.playbackEpisodeCount(se);
        if (ep > 0 && ep < count) return { season: se, episode: ep + 1 };
        var nextSeason = 0;
        for (var i = 0; i < root.playbackSeasons.length; i++) {
            var candidate = Number(root.playbackSeasons[i].se || 0);
            if (candidate > se && (nextSeason === 0 || candidate < nextSeason)) nextSeason = candidate;
        }
        return nextSeason > 0 && root.playbackEpisodeCount(nextSeason) > 0
             ? { season: nextSeason, episode: 1 }
             : null;
    }

    function playbackEpisodeCount(se) {
        for (var i = 0; i < root.playbackSeasons.length; i++)
            if (Number(root.playbackSeasons[i].se) === Number(se)) return Number(root.playbackSeasons[i].maxEp) || 0;
        return Number(se) === Number(root.playbackSeason) ? root.playbackInitialMaxEp : 0;
    }

    function episodeCode(se, ep) {
        return "S" + (se < 10 ? "0" : "") + se + "E" + (ep < 10 ? "0" : "") + ep;
    }

    function resetNextEpisode() {
        root.nextEpisodeThumb = null;
        root.nextThumbFetched = "";
        root.nextThumbPushed = "";
        root.nextEpisodeCandidate = null;
        root.nextEpisodeSeason = 0;
        root.nextEpisodeNumber = 0;
        root.nextEpisodeQueued = false;
        root.nextEpisodeWarmed = false;
        root.nextEpisodeTransitioned = false;
        root.nextEpisodeCancelled = false;
        root.nextEpisodeCountdown = 0;
        root.upNextText = "";
    }

    function prepareNextEpisode() {
        if (!root.playing || !root.playbackId || !root.activeStream || root.playbackProvider !== "stremio" || root.playbackStype !== 2) return;
        var next = root.nextEpisodeCoordinates(root.playbackSeason, root.playbackEpisode);
        root.resetNextEpisode();
        if (!next) {
            root.upNextText = "End of available episodes";
            return;
        }
        root.nextEpisodeSeason = next.season;
        root.nextEpisodeNumber = next.episode;
        root.upNextText = "Up next: " + root.episodeCode(next.season, next.episode) + " • finding a matching source…";
        if (prefetchStreamsProc.running) return;
        var req = JSON.stringify({
            cmd: "prepare_next",
            provider: "stremio",
            id: root.playbackId,
            season: next.season,
            episode: next.episode,
            currentStream: root.activeStream
        });
        prefetchStreamsProc.collected = "";
        prefetchStreamsProc.sessionPath = root.mpvSocketPath;
        prefetchStreamsProc.command = [root.bridge, req];
        prefetchStreamsProc.running = true;
    }

    function continuationLabel(stream) {
        var parts = [root.episodeCode(root.nextEpisodeSeason, root.nextEpisodeNumber)];
        if (stream.resolution) parts.push(stream.resolution + "p");
        if (stream.mediaLabel) parts.push(root.friendlyText(stream.mediaLabel));
        if (stream.sourceLabel) parts.push(root.friendlyText(stream.sourceLabel));
        return parts.join(" • ");
    }

    function handlePreparedEpisode(resp) {
        if (!root.playing || !resp || !resp.ok) {
            if (root.playing) root.upNextText = "Up next: preparation unavailable";
            return;
        }
        if (Number(resp.season || 0) !== root.nextEpisodeSeason || Number(resp.episode || 0) !== root.nextEpisodeNumber) return;
        if (!resp.selected) {
            root.upNextText = "Up next: " + root.episodeCode(root.nextEpisodeSeason, root.nextEpisodeNumber) + " • no matching source";
            return;
        }
        var prepared = root.sanitizeStreams([resp.selected]);
        root.nextEpisodeCandidate = prepared.length ? prepared[0] : null;
        if (!root.nextEpisodeCandidate) return;
        root.nextEpisodeWarmed = root.nextEpisodeCandidate.streamKind !== "p2p";
        root.upNextText = "Up next: " + root.continuationLabel(root.nextEpisodeCandidate) + " • prepared";
    }

    function play() {
        // Only mkv (mpv) — embedded view removed per request
        root.playExternal();
    }

    function playEmbedded() {
        if (root.selStream < 0 || root.streams.length === 0) return;
        var s = root.streams[root.selStream];
        var link = s.resourceLink || s.link || "";
        if (!link) { root.statusText = "Stream has no URL"; return; }
        root.playerUrl = link;
        root.playerTitle = root.currentTitle + (root.isSeries ? (" S" + root.curSeason + "E" + root.curEp) : "");
        root.view = "player";
        root.embeddedPlaying = true;
        root.statusText = "Playing \u201C" + root.playerTitle + "\u201D";
        // Defer source assignment to next tick to ensure view switch completes
        Qt.callLater(function() {
            embeddedPlayer.source = link;
            embeddedPlayer.play();
        });
    }

    function playExternal() {
        if (root.selStream < 0 || root.streams.length === 0) return;
        var s = root.streams[root.selStream];
        var link = s.resourceLink || s.link || "";
        if (!link) { root.statusText = "Stream has no URL"; return; }
        root.beginPlaybackSession(s);
        var args = root.mpvArgs(true);
        root.addResumeArgument(args);
        if (root.currentProvider === "stremio" && Array.isArray(s.headers)) {
            var addonFields = [];
            for (var hi = 0; hi < s.headers.length; hi++) {
                var hp = s.headers[hi];
                if (Array.isArray(hp) && hp.length >= 2) addonFields.push(String(hp[0]) + ": " + String(hp[1]));
            }
            if (s.streamKind === "p2p") addonFields.push("EngineFS-Prio: 255");
            if (addonFields.length) args.push("--http-header-fields=" + addonFields.join(","));
        }
        if (root.selectedSubtitle === "off") {
            args.push("--sid=no");
        } else if (root.selectedSubtitle === "auto") {
            // Nothing is handed to mpv here: these hosts are far slower than
            // mpv's network timeout. attachSubtitles() downloads them through
            // the bridge and attaches local files once playback is running.
            args.push("--sid=auto");
        } else {
            args.push("--sub-file=" + root.selectedSubtitle);
            args.push("--sid=auto");
        }
        var sourceLabel = root.currentProvider === "stremio" ? root.friendlyText(s.sourceLabel || "Addon") : "";
        var badge = root.friendlyText(s.streamBadge || (s.streamKind === "p2p" ? "Cached Stream" : "Fast Mirror"));
        var subLabel = sourceLabel ? (" • " + sourceLabel + " • " + badge) : "";
        if (root.currentProvider === "stremio" && s.streamKind === "p2p") {
            if (link === root.prefetchLink && root.prefetchState === "warming") {
                root._adoptWarmAndLaunch(args, link, subLabel);
            } else if (link === root.prefetchLink && root.prefetchState === "ready") {
                // Already warmed while the picker was open. The engine exists
                // and its peers are connected, so warming a second time would
                // only put the 1.9s ceiling back in front of mpv.
                root.resetPlaybackMetrics();
                root.metricPlayClickMs = Date.now();
                root.metricEngineReadyMs = root.metricPlayClickMs;
                root.streamHealthUrl = link;
                root.streamHealthState = "starting";
                root.streamHealthText = "Starting prepared stream\u2026";
                root.streamHealthPolls = 0;
                root.statusText = root.streamHealthText;
                root.clearPrefetch(false);
                root._launch(args, link, subLabel);
            } else {
                root._warmAndLaunch(args, link, subLabel);
            }
        } else {
            root._launch(args, link, subLabel);
        }
    }

    // mpv falls back to the raw stream URL for its window title, which is
    // unreadable in a tiling WM taskbar. Both the initial launch and the
    // auto-advanced next episode go through here so they stay consistent.
    // ---- trailer -----------------------------------------------------------
    readonly property var heroTrailer: root.tmdbTrailers.length > 0 ? root.tmdbTrailers[0] : null
    property string trailerThumbPath: ""

    onHeroTrailerChanged: {
        root.trailerThumbPath = "";
        if (root.heroTrailer && root.heroTrailer.thumb)
            root.setCachedImage(root.safeUrl(root.heroTrailer.thumb),
                                function(v) { root.trailerThumbPath = v; });
    }

    // mpv resolves YouTube through yt-dlp, so the trailer plays in the same
    // window as everything else rather than opening a browser.
    function playTrailer() {
        if (!root.heroTrailer || !root.heroTrailer.url) return;
        var args = ["mpv", "--force-window=immediate", "--no-terminal",
                    "--ytdl-format=bestvideo[height<=1080]+bestaudio/best",
                    "--force-media-title=" + (root.currentTitle || "Trailer") + " \u2014 Trailer"];
        args.push(root.heroTrailer.url);
        trailerProc.command = args;
        trailerProc.running = true;
        root.statusText = "Playing trailer \u2014 " + root.sanitize(root.heroTrailer.name || "");
    }

    Process {
        id: trailerProc
        onExited: function() { root.statusText = "Trailer closed"; }
    }

    // uosc replaces mpv's built-in OSC, but mpv only auto-loads scripts from
    // ~/.config/mpv/scripts and /etc/mpv/scripts. The Arch package installs to
    // /usr/share/mpv/scripts, which mpv never scans — so find where it actually
    // is and load it by path. Empty when uosc is not installed, in which case
    // the stock controls stay.
    property string uoscPath: ""
    readonly property bool uoscInstalled: root.uoscPath !== ""

    Process {
        id: uoscProbe
        running: true
        command: ["bash", "-c",
                  "for p in \"$HOME/.config/mpv/scripts/uosc\" /etc/mpv/scripts/uosc " +
                  "/usr/share/mpv/scripts/uosc; do [ -f \"$p/main.lua\" ] && { echo \"$p\"; exit 0; }; done"]
        stdout: SplitParser {
            onRead: function(line) { root.uoscPath = String(line).trim(); }
        }
    }

    readonly property string overlayScript: Qt.resolvedUrl("mpv/omacine.lua").toString().replace(/^file:\/\//, "")
    property string overlaySent: ""
    // Raw BGRA still for the Next Episode card, prepared once per episode.
    property var nextEpisodeThumb: null
    property string nextThumbFetched: ""
    property string nextThumbPushed: ""
    // Last loading card pushed to the player, so it is only re-sent on change.
    property string loadingSent: ""
    property string introFetched: ""
    property string playbackImdbId: ""
    property string introPushed: ""
    property var introWindow: null

    // Mirror the panel's up-next state into the mpv overlay. Sent only on
    // change: this rides the same 1s poll and must not spam the socket.
    // How close to the end the Next Episode button appears, in seconds. The
    // prepared episode is resolved minutes ahead, but showing the button then
    // is wrong: it belongs over the closing credits.
    readonly property int overlayLeadSeconds: 75
    // How close to the end the next episode may be added to mpv's playlist.
    // Long enough to append and prefetch, far enough from the start that a
    // stalled stream can never fall through into it.
    readonly property int nextEpisodeQueueLead: 180

    // Ask IntroDB for this episode's intro when the release ships no chapters.
    // Chapters are exact and always win inside the overlay; this only fills the
    // gap. Fire-and-forget: a miss is the common case and must stay silent.
    // Captions resolve asynchronously, so pressing Play early used to launch
    // with none and never recover. Attach them to the running player instead,
    // which also fills out the track list uosc shows.
    property string subsAttached: ""
    property string subsFetching: ""
    property string subsGateLogged: ""

    // Subtitles for whatever is actually playing.
    //
    // This deliberately does not reuse root.subs. That is browse-time state:
    // it is populated when a stream is selected, reset by navigation, and
    // flipped to "off" whenever one lookup happens to come back empty — so by
    // the time playback starts it may be stale or gone, and the player ends up
    // with an empty subtitle menu even though the add-on has tracks.
    //
    // Instead it asks for captions for the playing episode, downloads them
    // through the bridge (mpv's network timeout is shorter than these hosts
    // need), and attaches local files.
    function attachSubtitles() {
        var gateSignature = root.mpvSocketPath + "|" + root.playing + "|"
                          + root.playbackId + "|" + root.playbackStype + "|"
                          + root.playbackSeason + "|" + root.playbackEpisode;
        if (gateSignature !== root.subsGateLogged) {
            root.subsGateLogged = gateSignature;
            console.log("OMACINE attachSubtitles gate"
                        + " socket=" + root.mpvSocketPath
                        + " playing=" + root.playing
                        + " playbackId=" + root.playbackId
                        + " playbackType=" + root.playbackStype
                        + " season=" + root.playbackSeason
                        + " episode=" + root.playbackEpisode
                        + " commandBusy=" + mpvCommandProc.running);
        }
        if (!root.mpvSocketPath || !root.playing || !root.playbackId) return;
        var key = root.playbackId + "|" + root.playbackSeason + "|" + root.playbackEpisode;
        if (key === root.subsAttached || key === root.subsFetching) return;
        root.subsFetching = key;

        request("captions", {
            id: root.playbackId,
            provider: "stremio",
            season: root.playbackStype === 2 ? root.playbackSeason : 0,
            episode: root.playbackStype === 2 ? root.playbackEpisode : 0
        }, function(capResp) {
            var options = (capResp && capResp.ok && Array.isArray(capResp.options)) ? capResp.options : [];
            var urls = [];
            for (var i = 0; i < options.length && urls.length < 8; i++) {
                var url = root.safeUrl(options[i].url || "");
                if (url) urls.push(url);
            }
            if (urls.length === 0 || !root.playing) {
                root.subsFetching = "";
                root.subsAttached = key;      // nothing to attach; do not retry forever
                return;
            }
            request("subtitle_fetch", { urls: urls }, function(fetchResp) {
                root.subsFetching = "";
                if (!root.playing) return;
                var paths = (fetchResp && fetchResp.ok && fetchResp.paths) ? fetchResp.paths : {};
                var commands = [];
                for (var k = 0; k < urls.length; k++) {
                    // "auto" adds the track without stealing the current selection.
                    if (paths[urls[k]]) commands.push(["sub-add", paths[urls[k]], "auto"]);
                }
                if (commands.length === 0) return;
                if (root.sendMpvCommands(commands, "subtitles",
                                         { key: key, count: commands.length }))
                    root.subsFetching = key;
            });
        });
    }

    function loadIntroWindow() {
        if (!root.mpvSocketPath || !root.playing) return;
        if (root.playbackStype !== 2) return;
        if (root.playbackSeason < 1 || root.playbackEpisode < 1) return;
        // tmdbImdbId belongs to whatever details page is open, not to what is
        // playing. Browsing to another title mid-episode repointed it, and this
        // poller then fetched that show's intro timings and pushed them into the
        // running player. Latch the id once, only while the details page is
        // still the playing title; late TMDB enrichment is still picked up.
        if (!root.playbackImdbId && root.tmdbImdbId && root.currentId === root.playbackId)
            root.playbackImdbId = root.tmdbImdbId;
        if (!root.playbackImdbId) return;
        var wanted = root.playbackImdbId + "|" + root.playbackSeason + "|" + root.playbackEpisode;
        if (wanted === root.introFetched) return;
        root.introFetched = wanted;
        request("intro_lookup", { imdbId: root.playbackImdbId,
                                  season: root.playbackSeason,
                                  episode: root.playbackEpisode }, function(resp) {
            if (wanted !== root.introFetched || !root.playing) return;
            root.introWindow = (resp && resp.ok && resp.found === true)
                             ? { start: resp.start, end: resp.end,
                                 subs: resp.submissions || 0, key: wanted }
                             : null;
        });
    }

    // Handing the window to mpv is separate from fetching it: sendMpvCommands
    // refuses while its process is busy, and the old code recorded the send
    // before it happened, so one collision lost the intro for the whole
    // episode. Retried on the next poll until it actually goes out.
    function pushIntroWindow() {
        if (!root.introWindow) return;
        var window = root.introWindow;
        if (window.key === root.introPushed) return;
        if (root.sendMpvCommands([["script-message", "omacine-intro",
                                   String(window.start), String(window.end),
                                   String(window.subs)]], "intro"))
            root.introPushed = window.key;
    }

    function loadNextThumb() {
        if (!root.mpvSocketPath || !root.playing) return;
        if (!root.nextEpisodeSeason || !root.nextEpisodeNumber) return;
        var key = root.playbackId + "|" + root.nextEpisodeSeason + "|" + root.nextEpisodeNumber;
        if (key === root.nextThumbFetched) return;
        // tmdbEpisodes belongs to whatever details page is open, not to what is
        // playing - the same trap the intro lookup fell into. Only read it while
        // the page still shows this title, on the season the next episode is in.
        if (root.currentId !== root.playbackId) return;
        if (Number(root.curSeason) !== Number(root.nextEpisodeSeason)) return;
        // The still is already on disk: the details page cached it when the
        // season loaded, so this is a conversion, not a download.
        var still = "";
        for (var i = 0; i < root.tmdbEpisodes.length; i++) {
            var ep = root.tmdbEpisodes[i];
            if (Number(ep.episode) === Number(root.nextEpisodeNumber)) {
                still = String(ep.still || ep.image || "");
                break;
            }
        }
        // Only a cached local file can be converted; an http URL means the
        // artwork cache has not caught up yet, so try again on a later tick.
        if (!still || still.indexOf("http") === 0) return;
        root.nextThumbFetched = key;
        request("thumb_raw", { source: still, width: 320, height: 180 }, function(resp) {
            if (key !== root.nextThumbFetched || !root.playing) return;
            if (!resp || !resp.ok || !resp.path) return;
            root.nextEpisodeThumb = { path: resp.path, w: resp.width,
                                      h: resp.height, stride: resp.stride, key: key };
        });
    }

    function pushNextThumb() {
        if (!root.nextEpisodeThumb) return;
        var thumb = root.nextEpisodeThumb;
        if (thumb.key === root.nextThumbPushed) return;
        if (root.sendMpvCommands([["script-message", "omacine-thumb", String(thumb.path),
                                   String(thumb.w), String(thumb.h), String(thumb.stride)]], "thumb"))
            root.nextThumbPushed = thumb.key;
    }

    // While a torrent is finding peers mpv shows a black frame, which looks
    // identical to a hang. This puts the title and what it is doing on screen
    // until the first real frame arrives.
    function syncLoadingCard() {
        if (!root.mpvSocketPath || !root.playing) return;
        var title = "";
        var detail = "";
        // playbackPosition only moves once decoding starts, so it is the
        // honest signal that the card is no longer needed.
        if (root.playbackPosition <= 0.2) {
            title = root.mediaTitle(root.playbackSeason, root.playbackEpisode);
            detail = root.friendlyText(root.streamHealthText || "Connecting to the media source…");
        }
        var signature = title + "|" + detail;
        if (signature === root.loadingSent) return;
        if (root.sendMpvCommands([["script-message", "omacine-loading",
                                   title.slice(0, 190), detail.slice(0, 190)]], "loading"))
            root.loadingSent = signature;
    }

    function syncOverlay(remaining) {
        if (!root.mpvSocketPath || !root.playing) return;
        var label = "";
        var ready = "0";
        var countdown = "";
        var nearEnd = remaining !== undefined && remaining >= 0
                      && remaining <= root.overlayLeadSeconds;
        if (nearEnd && root.nextEpisodeCandidate && !root.nextEpisodeCancelled) {
            label = root.episodeCode(root.nextEpisodeSeason, root.nextEpisodeNumber);
            var stream = root.nextEpisodeCandidate;
            if (stream.resolution) label += "  \u2022  " + stream.resolution + "p";
            ready = root.nextEpisodeQueued ? "1" : "0";
            if (root.nextEpisodeCountdown > 0) countdown = String(root.nextEpisodeCountdown);
        }
        var signature = label + "|" + ready + "|" + countdown;
        if (signature === root.overlaySent) return;
        // Only remember it once the socket actually took it.
        // Only forget that it was *pushed* - the script drops its copy on
        // omacine-clear, so it must be sent again when the card returns. The
        // converted still itself is kept: discarding it here threw away the
        // fetched thumbnail on every tick the card was hidden, while
        // nextThumbFetched still blocked a re-fetch, so it never arrived.
        if (label === "") root.nextThumbPushed = "";
        var sent = (label === "")
                 ? root.sendMpvCommands([["script-message", "omacine-clear"]], "overlay")
                 : root.sendMpvCommands([["script-message", "omacine-upnext",
                                          label, ready, countdown]], "overlay");
        if (sent) root.overlaySent = signature;
    }

    // ---- theme songs (ThemerrDB) --------------------------------------------
    // A theme belongs to a show or a movie, never to an episode, so this only
    // ever runs on a details page. Unrelated to Skip Intro, which is per
    // episode and comes from IntroDB.
    property string themePlaying: ""     // media id currently on air
    property string themeWanted: ""      // media id being resolved
    property int themeGen: 0

    // Netflix's move: the still backdrop holds the frame, then the clip fades
    // in over it. Kept false until the reveal timer fires.
    property bool themeVideoShown: false

    function stopTheme() {
        root.themeGen++;                 // discards any in-flight lookup
        root.themeWanted = "";
        root.themePlaying = "";
        if (themeProc.running) themeProc.running = false;
        themeVideoReveal.stop();
        root.themeVideoShown = false;
        if (themeVideoPlayer.playbackState !== MediaPlayer.StoppedState) themeVideoPlayer.stop();
        themeVideoPlayer.source = "";
    }

    function startThemeFor(mediaId) {
        if (!mediaId || root.settings.themeSongs !== true) { root.stopTheme(); return; }
        if (mediaId === root.themePlaying) return;      // already playing this one
        root.stopTheme();
        root.themeWanted = mediaId;
        var gen = root.themeGen;
        // theme_fetch resolves and downloads in one call. A title already in
        // the cache comes back in ~60ms; a new one takes a few seconds, which
        // is why every guard below is re-checked when it returns.
        var wantVideo = root.settings.themeVideo === true;
        // The title is what lets the bridge fall back to a search when
        // ThemerrDB has no entry, or its entry points at a removed video.
        var name = root.currentTitle || "";
        var year = (root.details && root.details.year) ? String(root.details.year) : "";
        request("theme_fetch", { id: mediaId, title: name, year: year,
                                 mediaKind: wantVideo ? "video" : "audio" },
                function(resp) {
            if (gen !== root.themeGen || root.themeWanted !== mediaId) return;
            if (root.view !== "details" || root.currentId !== mediaId) return;
            if (root.playing) return;
            if (!resp || !resp.ok || resp.found !== true) return;
            if (wantVideo && resp.videoReady === true && resp.videoPath) {
                root.playThemeVideo(resp.videoPath, mediaId);
            } else if (resp.audioReady === true && resp.audioPath) {
                root.playTheme(resp.audioPath, mediaId);
            } else if (wantVideo) {
                // No usable backdrop clip for this title - the theme song on
                // its own is still worth having, so fall back rather than
                // leaving the page silent.
                request("theme_fetch", { id: mediaId, title: name, mediaKind: "audio" }, function(audio) {
                    if (gen !== root.themeGen || root.themeWanted !== mediaId) return;
                    if (root.view !== "details" || root.currentId !== mediaId) return;
                    if (root.playing) return;
                    if (audio && audio.ok && audio.audioReady === true && audio.audioPath)
                        root.playTheme(audio.audioPath, mediaId);
                });
            }
        });
    }

    property bool themeEditOpen: false
    property string themeEditText: ""
    property string themeEditNote: ""

    function saveThemeUrl(url) {
        if (!root.currentId) return;
        var target = root.currentId;
        root.themeEditNote = "Saving\u2026";
        request("theme_set_url", { id: target, url: url }, function(resp) {
            if (root.currentId !== target) return;
            if (!resp || !resp.ok) {
                root.themeEditNote = root.friendlyText((resp && resp.error) || "Could not save that link");
                return;
            }
            root.themeEditNote = url ? "Saved \u2014 fetching\u2026" : "Reverted to ThemerrDB";
            root.themeEditOpen = false;
            root.themeEditText = "";
            // The pinned URL invalidates whatever was cached, so replay from scratch.
            root.stopTheme();
            root.startThemeFor(target);
        });
    }

    function playThemeVideo(path, mediaId) {
        var volume = Number(root.settings.themeVolume);
        if (isNaN(volume)) volume = 45;
        themeVideoAudio.volume = Math.max(0, Math.min(100, volume)) / 100;
        themeVideoPlayer.source = "file://" + path;
        themeVideoPlayer.play();
        root.themePlaying = mediaId;
        root.themeWanted = "";
        root.themeVideoShown = false;
        var delay = Number(root.settings.themeVideoDelay);
        themeVideoReveal.interval = Math.round(Math.max(0, isNaN(delay) ? 1.8 : delay) * 1000);
        themeVideoReveal.restart();
    }

    function playTheme(path, mediaId) {
        var volume = Number(root.settings.themeVolume);
        if (isNaN(volume)) volume = 45;
        volume = Math.max(0, Math.min(100, Math.round(volume)));
        if (volume === 0) return;
        themeProc.command = [
            "mpv", "--no-video", "--no-terminal", "--really-quiet",
            "--idle=no", "--loop-file=inf",
            "--volume=" + volume,
            // Themes cut in hard otherwise, which is jarring when a page opens.
            "--af=afade=t=in:d=1.5",
            path
        ];
        themeProc.running = true;
        root.themePlaying = mediaId;
        root.themeWanted = "";
    }

    function mediaTitle(season, episode) {
        var name = root.playbackTitle || root.currentTitle || "OmaCine";
        return (Number(root.playbackStype) === 2 && Number(episode) > 0)
             ? name + " \u2014 " + root.episodeCode(Number(season), Number(episode))
             : name;
    }

    function mpvArgs(persistent) {
        var args = [
            "mpv",
            "--force-window=immediate",
            "--no-terminal",
            "--cache=yes",
            // Kept in RAM. The streaming cache already writes every one of
            // these bytes to the NVMe; mirroring them into a second on-disk
            // buffer doubled the write load during decode and mpv discards
            // that copy at exit anyway. demuxer-max-bytes below is the real
            // buffer, and 512 MiB is affordable in a 16 GB machine.
            "--cache-pause=yes",
            // Deliberately kept on. On a 17 Mbit/s link, starting instantly and
            // then stalling feels worse than waiting a moment for a buffer.
            "--cache-pause-initial=yes",
            "--cache-pause-wait=1",
            // ffmpeg otherwise reads megabytes to identify every track before
            // showing frame one, which is 2-4s of black screen that has nothing
            // to do with the network. 1 MB is well past what a container header
            // needs: a test MKV with 2 audio and 2 subtitle tracks resolved all
            // five at 64 KB, so this keeps a wide margin over the known-good.
            "--demuxer-lavf-probesize=1000000",
            "--demuxer-lavf-analyzeduration=1",
            // Decode on the GPU. auto-safe only picks a backend known to work
            // for the codec, so it falls back to software rather than breaking.
            "--hwdec=auto-safe",
            // A VO list, not a single name: if gpu-next cannot initialise on
            // this session mpv falls back to gpu instead of refusing to start.
            "--vo=gpu-next,gpu",
            // This pair is what actually bounds the readahead. cache-secs
            // defaults to 3600000, so it always wins the "larger value"
            // override against demuxer-readahead-secs and leaves the byte
            // budget in charge: ~400s of a 10 Mbit/s 1080p stream, ~50s of
            // an 80 Mbit/s 4K remux. Do not set cache-secs to a small number
            // to "increase" the buffer - it can only shrink it.
            "--demuxer-max-bytes=512MiB",
            "--demuxer-max-back-bytes=128MiB",
            "--hr-seek=yes",
            // A slow swarm needs longer than ten seconds to produce the first
            // bytes. This is how long mpv will keep trying before giving up.
            "--network-timeout=60",
            // Do not vanish when a stream fails or the playlist runs out.
            // Closing to a bare desktop gives no clue what happened; staying
            // open lets the overlay say so. keep-open only holds the *last*
            // entry, so a queued next episode still advances normally.
            "--idle=yes",
            "--keep-open=yes",
            "--force-seekable=yes",
            "--force-media-title=" + root.mediaTitle(root.playbackSeason, root.playbackEpisode),
            // Skip Intro / Next Episode drawn over the video, so they are
            // reachable in fullscreen where this panel is not. Per-launch, so
            // it never touches the user's own mpv configuration.
            "--script=" + root.overlayScript
        ];
        // Load uosc by path and retire the stock OSC. Only when it is really
        // there — otherwise --osc=no would leave the player with no controls.
        if (root.uoscInstalled) {
            args.push("--script=" + root.uoscPath);
            args.push("--osc=no");
        }
        if (persistent && root.mpvSocketPath) {
            args.push("--input-ipc-server=" + root.mpvSocketPath);
            args.push("--prefetch-playlist=yes");
        }
        return args;
    }

    function watchEntryFor(providerName, mediaId, season, episode) {
        for (var i = 0; i < root.watchEntries.length; i++) {
            var entry = root.watchEntries[i];
            if (String(entry.provider || "") === String(providerName || "")
                    && String(entry.id || "") === String(mediaId || "")
                    && Number(entry.season || 0) === Number(season || 0)
                    && Number(entry.episode || 0) === Number(episode || 0)) return entry;
        }
        return null;
    }

    function resumePositionFor(providerName, mediaId, season, episode) {
        var entry = root.watchEntryFor(providerName, mediaId, season, episode);
        if (!entry || entry.completed === true) return 0;
        var position = Number(entry.position || 0);
        // "Completed" is ratio >= 0.92, but the Next Episode overlay arms at 75s
        // remaining. Those two only agree above a ~15.6 minute runtime; below it
        // an un-completed entry can resume already inside the overlay window, so
        // a short episode reopened at the tail showed Next Episode instantly and
        // counted itself down into the following one. Anything inside the last
        // lead-in is treated as finished and restarts.
        var duration = Number(entry.duration || 0);
        if (duration > 0 && duration - position <= root.overlayLeadSeconds) return 0;
        return position >= 15 ? position : 0;
    }

    function isEpisodeWatched(season, episode) {
        var entry = root.watchEntryFor(root.currentProvider, root.currentId, season, episode);
        return entry ? entry.completed === true : false;
    }

    function episodeProgressLabel(season, episode) {
        var entry = root.watchEntryFor(root.currentProvider, root.currentId, season, episode);
        if (!entry) return "E" + episode;
        if (entry.completed === true) return "✓ E" + episode;
        var progress = Math.round(Number(entry.progress || 0) * 100);
        return "E" + episode + (progress >= 2 ? ("  " + progress + "%") : "");
    }

    function addResumeArgument(args) {
        // Applies to the whole playlist, not just this file - queued episodes
        // pass their own start=0 to override it. See nextStreamOptions().
        if (root.playbackPosition >= 15) args.push("--start=" + Math.floor(root.playbackPosition));
    }

    function beginPlaybackSession(stream) {
        root.stopTheme();
        root.mpvSocketPath = root.runtimeDir + "/omamovie-mpv-" + Date.now() + ".sock";
        root.playbackProvider = root.currentProvider;
        root.playbackId = root.currentId;
        root.playbackTitle = root.currentTitle;
        root.playbackCover = root.currentCover || root.coverUrlOf(root.details);
        root.playbackStype = root.isSeries ? 2 : 1;
        root.playbackSeasons = root.seasons;
        root.playbackSeason = root.isSeries ? root.curSeason : 0;
        root.playbackEpisode = root.isSeries ? root.curEp : 0;
        root.playbackInitialMaxEp = root.maxEp;
        root.playbackPosition = root.resumePositionFor(root.currentProvider, root.currentId, root.playbackSeason, root.playbackEpisode);
        root.playbackDuration = 0;
        root.lastWatchSaveMs = 0;
        root.activeStream = stream;
        root.subs = root.normalizeSubtitles(stream.subtitles || []);
        root.selectedSubtitle = root.subs.length ? "auto" : "off";
        root.resetNextEpisode();
    }

    function clearPlaybackSession() {
        root.resetPlaybackMetrics();
        root.overlaySent = "";
        root.loadingSent = "";
        root.introFetched = "";
        root.introPushed = "";
        root.playbackImdbId = "";
        root.nextEpisodeThumb = null;
        root.nextThumbFetched = "";
        root.nextThumbPushed = "";
        root.introWindow = null;
        root.subsAttached = "";
        root.subsFetching = "";
        root.subsGateLogged = "";
        root.mpvPendingSubtitle = null;
        root.mpvSocketPath = "";
        root.playbackProvider = "";
        root.playbackId = "";
        root.playbackTitle = "";
        root.playbackCover = "";
        root.playbackStype = 1;
        root.playbackSeasons = [];
        root.playbackSeason = 0;
        root.playbackEpisode = 0;
        root.playbackInitialMaxEp = 0;
        root.playbackPosition = 0;
        root.playbackDuration = 0;
        root.lastWatchSaveMs = 0;
        root.activeStream = null;
        root.resetNextEpisode();
    }

    // ---- stream prefetch ---------------------------------------------------
    // Creating the engine, announcing to trackers and finding peers that will
    // actually unchoke takes seconds, and today all of it starts on the Play
    // click. Selecting a row is a separate action here, so that work can run
    // while the list is still being read. Only ever the selected row: warming
    // a whole list would spend real bandwidth on streams never played.

    function currentStreamLink() {
        if (root.selStream < 0 || root.selStream >= root.streams.length) return "";
        var s = root.streams[root.selStream];
        if (!s || s.streamKind !== "p2p") return "";
        return s.resourceLink || "";
    }

    function schedulePrefetch() {
        if (root.settings.prefetchStreams !== true) return;
        if (root.playing || root.streamConnecting) return;
        if (root.currentProvider !== "stremio") return;
        if (!root.currentStreamLink()) return;
        streamWarmDebounce.restart();
    }

    // Hand engines back through a queue. A single Process cannot take a second
    // command while it is running - the assignment is simply dropped - so
    // releases fired faster than they complete used to be lost, which on a
    // metered connection means a swarm left running for a row merely glanced
    // at. Nothing that is playing or currently warming is ever released.
    // The release route removes a whole torrent engine, not one file within
    // it, so protection is compared by info hash. Two picker rows pointing at
    // different files of the same torrent share one engine, and releasing
    // either would tear the other down.
    function infoHashOf(link) {
        var found = /\/([0-9a-fA-F]{40})(?:\/|$|\?)/.exec(String(link || ""));
        return found ? found[1].toLowerCase() : "";
    }

    function releasePrefetch(link) {
        if (!link || !root.infoHashOf(link)) return;
        if (root.releaseQueue.indexOf(link) >= 0) return;
        var queued = root.releaseQueue.slice();
        queued.push(link);
        root.releaseQueue = queued;
        root.drainReleaseQueue();
    }

    function drainReleaseQueue() {
        if (streamReleaseProc.running || root.releaseQueue.length === 0) return;
        // Guarded at the moment of sending rather than when queued. The warm
        // in flight matters most: its own range request would recreate the
        // engine moments after we removed it, leaving an orphan running.
        var guarded = ({});
        var protect = function(url) {
            var hash = root.infoHashOf(url);
            if (hash) guarded[hash] = true;
        };
        protect(root.streamHealthUrl);
        protect(root.prefetchLink);
        protect(streamWarmProc.activeLink);

        var queued = root.releaseQueue.slice();
        for (var i = 0; i < queued.length; i++) {
            if (guarded[root.infoHashOf(queued[i])]) continue;
            var link = queued[i];
            queued.splice(i, 1);
            root.releaseQueue = queued;
            streamReleaseProc.command = [root.bridge,
                JSON.stringify({ cmd: "release_stream", url: link })];
            streamReleaseProc.running = true;
            return;
        }
        // Everything still queued is in use. Left in place deliberately: the
        // next warm or release exit drains again once the guard has lifted.
    }

    // Every warm carries the generation it was issued under. A reply whose
    // generation has moved on belongs to a row the user already left, so it
    // must not mark the current row ready.
    function runPrefetch() {
        var link = root.currentStreamLink();
        if (!link) return;
        if (root.playing || root.streamConnecting) return;
        if (link === root.prefetchLink && root.prefetchState !== "idle") return;
        root.prefetchGen++;
        root.prefetchLink = link;
        root.prefetchState = "warming";
        if (streamWarmProc.running) {
            // Cannot retask a running Process; start this one when it exits.
            root.pendingWarmLink = link;
            return;
        }
        root.startWarm(link, root.prefetchGen);
    }

    function startWarm(link, generation) {
        streamWarmProc.generation = generation;
        streamWarmProc.activeLink = link;
        streamWarmProc.collected = "";
        streamWarmProc.command = [root.bridge,
            JSON.stringify({ cmd: "warm_stream", url: link })];
        streamWarmProc.running = true;
    }

    function clearPrefetch(release) {
        streamWarmDebounce.stop();
        var link = root.prefetchLink;
        // Bumping the generation orphans any warm still in flight, so its
        // reply cannot mark a stream we are no longer interested in ready.
        root.prefetchGen++;
        root.pendingWarmLink = "";
        root.prefetchLink = "";
        root.prefetchState = "idle";
        if (release) root.releasePrefetch(link);
    }

    onSelStreamChanged: {
        if (root.prefetchLink && root.currentStreamLink() !== root.prefetchLink)
            root.clearPrefetch(true);
        root.schedulePrefetch();
    }

    function resetPlaybackMetrics() {
        root.metricPlayClickMs = 0;
        root.metricEngineReadyMs = 0;
        root.metricMpvLaunchMs = 0;
        root.metricFirstFrameMs = 0;
        root.metricRebuffers = 0;
        root.metricStartupPolls = 0;
        root.metricRebufferMs = 0;
        root.metricStarvedSinceMs = 0;
        root.bufferAheadSecs = 0;
        root.cacheSpeedBps = 0;
    }

    // One line per playback, so a slow start can be attributed to a phase
    // rather than guessed at. Every span is relative to the Play click.
    function logPlaybackMetrics(reason) {
        if (root.metricPlayClickMs <= 0) return;
        var span = function(ms) {
            return ms > 0 ? (((ms - root.metricPlayClickMs) / 1000).toFixed(2) + "s") : "n/a";
        };
        console.log("OmaCine playback [" + reason + "]"
                  + " engine=" + span(root.metricEngineReadyMs)
                  + " mpv=" + span(root.metricMpvLaunchMs)
                  + " firstFrame=" + span(root.metricFirstFrameMs)
                  + " rebuffers=" + root.metricRebuffers
                  + " rebufferTotal=" + (root.metricRebufferMs / 1000).toFixed(2) + "s"
                  + " bufferAhead=" + root.bufferAheadSecs.toFixed(1) + "s"
                  + " watched=" + root.playbackPosition.toFixed(0) + "s");
    }

    function _warmAndLaunch(args, link, subLabel) {
        if (root.streamConnecting || root.playing) return;
        root.resetPlaybackMetrics();
        root.metricPlayClickMs = Date.now();
        root.streamConnecting = true;
        root.streamHealthUrl = link;
        root.streamHealthState = "starting";
        root.streamHealthText = "Starting local stream engine…";
        root.streamHealthPolls = 0;
        root.statusText = root.streamHealthText;
        root.warmupArgs = args;
        root.warmupLink = link;
        root.warmupLabel = subLabel;
        warmupProc.collected = "";
        warmupProc.command = [root.bridge, JSON.stringify({ cmd: "warm_stream", url: link })];
        warmupProc.running = true;
        warmupFallback.restart();
    }

    // Play pressed while the picker's warm is still running. Set up exactly
    // the state _warmAndLaunch would, but spawn nothing: streamWarmProc's exit
    // completes it. Without this, Play started a second warm_stream for a URL
    // already being warmed.
    function _adoptWarmAndLaunch(args, link, subLabel) {
        if (root.streamConnecting || root.playing) return;
        root.resetPlaybackMetrics();
        root.metricPlayClickMs = Date.now();
        root.streamConnecting = true;
        root.streamHealthUrl = link;
        root.streamHealthState = "starting";
        root.streamHealthText = "Finishing the prepared stream\u2026";
        root.streamHealthPolls = 0;
        root.statusText = root.streamHealthText;
        root.warmupArgs = args;
        root.warmupLink = link;
        root.warmupLabel = subLabel;
        warmupFallback.restart();
    }

    function _completeWarmup() {
        if (!root.streamConnecting) return;
        root.metricEngineReadyMs = Date.now();
        warmupFallback.stop();
        var args = root.warmupArgs;
        var link = root.warmupLink;
        var label = root.warmupLabel;
        root.warmupArgs = [];
        root.warmupLink = "";
        root.warmupLabel = "";
        root.streamConnecting = false;
        root._launch(args, link, label);
    }

    function _launch(args, link, subLabel) {
        args.push(link);
        mpvProc.command = args;
        mpvProc.running = true;
        root.metricMpvLaunchMs = Date.now();
        root.playing = true;
        if (!root.streamHealthUrl) root.statusText = "Playing in mpv" + subLabel + " \u2022 close the player to stop";
        if (root.mpvSocketPath) Qt.callLater(function(){ root.prepareNextEpisode(); });
    }

    function pollStreamHealth() {
        if (!root.streamHealthUrl) return;
        if (root.streamStatusInFlight
                && Date.now() - root.streamStatusSentMs < root.telemetryStallMs) return;
        var target = root.streamHealthUrl;
        root.streamStatusGeneration++;
        var generation = root.streamStatusGeneration;
        root.streamStatusInFlight = true;
        root.streamStatusSentMs = Date.now();
        root.request("stream_status", { url: target }, function(resp) {
            if (generation !== root.streamStatusGeneration) return;
            root.streamStatusInFlight = false;
            if (target !== root.streamHealthUrl) return;
            root.updateStreamHealth(resp);
        });
    }

    function updateStreamHealth(resp) {
        if (!root.streamHealthUrl) return;
        root.streamHealthPolls++;
        var stats = resp && resp.ok ? resp.value : null;
        if (!stats || stats.available !== true) {
            root.streamHealthState = "starting";
            root.streamHealthText = root.streamConnecting
                                  ? "Starting local stream engine…"
                                  : "Waiting for connection details…";
            root.statusText = root.streamHealthText;
            return;
        }
        var sources = Number(stats.sources || 0);
        var active = Number(stats.active || 0);
        var attempts = Number(stats.attempts || 0);
        var rate = Number(stats.receiveRate || 0);
        var progress = Number(stats.cachedProgress || 0);
        var progressText = root.cachedPercent(progress);
        // A high cached percentage with no frame is the signature of a source
        // whose seek index has not arrived. streamProgress counts pieces held
        // anywhere in the file, so it can read 86% while the end - where an
        // MKV keeps the Cues mpv must parse before showing frame one - is
        // still missing. Say that, rather than repeating a number that looks
        // like everything is fine.
        if (root.playing && !root.warmTailReady && root.metricFirstFrameMs <= 0
                && root.streamHealthPolls > 12 && progress > 0.4) {
            root.streamHealthState = "indexing";
            root.streamHealthText = "Waiting for this source's seek index \u2014 "
                                  + (progressText ? progressText + ", " : "")
                                  + "but the end of the file is still arriving"
                                  + (sources > 0 ? (" \u2022 " + sources + (sources === 1 ? " source" : " sources")) : "")
                                  + (rate > 0 ? (" \u2022 " + root.fmtRate(rate)) : " \u2022 stalled, try another source");
            root.statusText = root.streamHealthText;
            return;
        }
        if (progress >= 0.995) {
            root.streamHealthState = "ready";
            root.streamHealthText = "Ready from local cache" + (sources > 0 ? (" • " + sources + " sources connected") : "");
        } else if (rate > 0) {
            root.streamHealthState = "receiving";
            // bufferAhead is what actually decides whether playback stalls;
            // progressText counts pieces held anywhere in the file and can
            // look healthy while the next piece needed is still missing.
            root.streamHealthText = "Receiving media • "
                                  + sources + (sources === 1 ? " source" : " sources")
                                  + (active > 0 ? (" • " + active + " active") : "")
                                  + " • " + root.fmtRate(rate)
                                  + (root.playing && root.bufferAheadSecs > 0
                                        ? (" • " + root.bufferAheadSecs.toFixed(0) + "s buffered")
                                        : "")
                                  + (progressText ? (" • " + progressText) : "");
        } else if (sources > 0) {
            root.streamHealthState = "connected";
            root.streamHealthText = "Connected to " + sources + (sources === 1 ? " source" : " sources")
                                  + (active > 0 ? (" • " + active + " active") : "")
                                  + " • waiting for media data…";
        } else {
            root.streamHealthState = "discovering";
            root.streamHealthText = "Discovering community sources…"
                                  + (attempts > 0 ? (" • " + attempts + " connection attempts") : "");
        }
        root.statusText = root.streamHealthText;
    }

    Timer {
        id: streamHealthTimer
        interval: root.streamHealthPolls < 20 ? 750 : 2000
        repeat: true
        running: root.streamHealthUrl !== "" && (root.streamConnecting || root.playing)
        triggeredOnStart: true
        onTriggered: root.pollStreamHealth()
    }

    function nextStreamOptions(stream) {
        // --start is a *global* mpv option: it applies to every file in the
        // playlist, so resuming this episode at 10:00 also started the next one
        // at 10:00. A per-file start of 0 overrides it for the queued entry.
        var options = { "force-media-title": root.mediaTitle(root.nextEpisodeSeason, root.nextEpisodeNumber),
                        "start": "0" };
        var fields = [];
        var headers = stream.headers || [];
        for (var i = 0; i < headers.length; i++) {
            var pair = headers[i];
            if (Array.isArray(pair) && pair.length >= 2) fields.push(String(pair[0]) + ": " + String(pair[1]));
        }
        if (stream.streamKind === "p2p") fields.push("EngineFS-Prio: 255");
        if (fields.length) options["http-header-fields"] = fields.join(",");
        return options;
    }

    function sendMpvCommands(commands, purpose, context) {
        if (!root.mpvSocketPath || !commands || !commands.length) return false;
        if (mpvCommandProc.running) {
            if (purpose === "subtitles") {
                root.mpvPendingSubtitle = {
                    commands: commands,
                    context: context || null
                };
                console.log("OMACINE subtitles queued: mpv command helper busy with "
                            + root.mpvCommandPurpose);
                return true;
            }
            return false;
        }
        root.mpvCommandPurpose = purpose || "";
        root.mpvCommandContext = context || null;
        mpvCommandProc.collected = "";
        mpvCommandProc.command = [root.bridge, JSON.stringify({
            cmd: "mpv_command",
            socketPath: root.mpvSocketPath,
            commands: commands
        })];
        mpvCommandProc.running = true;
        return true;
    }

    function dispatchPendingSubtitle() {
        var pending = root.mpvPendingSubtitle;
        if (!pending || mpvCommandProc.running || !root.playing) return;
        root.mpvPendingSubtitle = null;
        var context = pending.context || null;
        var currentKey = root.playbackId + "|" + root.playbackSeason + "|" + root.playbackEpisode;
        if (!context || context.key !== currentKey) {
            root.subsFetching = "";
            return;
        }
        if (!root.sendMpvCommands(pending.commands, "subtitles", context))
            root.subsFetching = "";
    }

    function queuePreparedEpisode() {
        if (!root.nextEpisodeCandidate || root.nextEpisodeQueued || root.nextEpisodeTransitioned || root.nextEpisodeCancelled) return;
        var link = root.safeUrl(root.nextEpisodeCandidate.resourceLink || "");
        if (!link) return;
        var command = ["loadfile", link, "insert-next", -1, root.nextStreamOptions(root.nextEpisodeCandidate)];
        if (root.sendMpvCommands([command], "queue-next"))
            root.upNextText = "Up next: " + root.continuationLabel(root.nextEpisodeCandidate) + " • adding to player…";
    }

    function pollMpvState() {
        if (!root.mpvSocketPath) return;
        if (root.mpvStatusInFlight
                && Date.now() - root.mpvStatusSentMs < root.telemetryStallMs) return;
        // Captured, not read again in the callback: by the time this returns
        // the player may have been replaced, and a reply describing the old
        // session must not be applied to the new one.
        var session = root.mpvSocketPath;
        root.mpvStatusGeneration++;
        var generation = root.mpvStatusGeneration;
        root.mpvStatusInFlight = true;
        root.mpvStatusSentMs = Date.now();
        root.request("mpv_status", { socketPath: session }, function(resp) {
            // A reply that no longer owns the channel is not merely stale: it
            // must not free the in-flight flag its successor is holding.
            if (generation !== root.mpvStatusGeneration) return;
            root.mpvStatusInFlight = false;
            if (session !== root.mpvSocketPath) return;
            root.updateMpvState(resp);
        });
    }

    function updateMpvState(resp) {
        var state = resp && resp.ok ? resp.value : null;
        if (!state || state.available !== true || !root.playing) return;
        root.mpvPlaylistPosition = Number(state["playlist-pos"] !== undefined ? state["playlist-pos"] : -1);
        root.playbackPosition = Math.max(0, Number(state["time-pos"] || 0));
        root.playbackDuration = Math.max(0, Number(state.duration || 0));
        root.bufferAheadSecs = Math.max(0, Number(state["demuxer-cache-duration"] || 0));
        root.cacheSpeedBps = Math.max(0, Number(state["cache-speed"] || 0));
        // A decoded position is the first thing mpv can only report once a
        // frame exists, so it stands in for first frame without a second IPC.
        if (root.metricFirstFrameMs <= 0 && root.playbackPosition > 0) {
            root.metricFirstFrameMs = Date.now();
            root.logPlaybackMetrics("first-frame");
        }
        // Rebuffering is only counted after the first frame: the initial fill
        // is cache-pause-initial doing its job, not a stall.
        var starved = state["paused-for-cache"] === true;
        if (starved && root.metricStarvedSinceMs <= 0) {
            root.metricStarvedSinceMs = Date.now();
            if (root.metricFirstFrameMs > 0) root.metricRebuffers++;
        } else if (!starved && root.metricStarvedSinceMs > 0) {
            if (root.metricFirstFrameMs > 0)
                root.metricRebufferMs += Date.now() - root.metricStarvedSinceMs;
            root.metricStarvedSinceMs = 0;
        }
        if (root.playbackPosition > 0 && Date.now() - root.lastWatchSaveMs >= 5000) root.queueWatchSave(false);
        var nextLink = root.nextEpisodeCandidate ? (root.nextEpisodeCandidate.resourceLink || "") : "";
        if (nextLink && state.path === nextLink && !root.nextEpisodeTransitioned) {
            root.activateNextEpisode();
            return;
        }
        var remaining = Number(state["time-remaining"]);
        // The next episode is appended to mpv's playlist only once this one is
        // genuinely near its end. It used to be queued seconds after playback
        // started, which meant a stream that stalled or failed to load did not
        // stop - mpv simply advanced to the next playlist entry and silently
        // skipped an episode. With nothing queued, a failing stream now just
        // stops, which is the honest outcome.
        var nearEnough = !isNaN(remaining) && remaining > 0 && remaining <= root.nextEpisodeQueueLead;
        if (nearEnough && root.nextEpisodeCandidate && !root.nextEpisodeQueued
                && !root.nextEpisodeCancelled && !root.nextEpisodeTransitioned
                && !mpvCommandProc.running)
            root.queuePreparedEpisode();
        if (root.nextEpisodeQueued && !root.nextEpisodeWarmed && remaining > 0 && remaining <= 90)
            root.warmPreparedEpisode();
        if (root.nextEpisodeQueued && !root.nextEpisodeCancelled && remaining >= 0 && remaining <= 10) {
            root.nextEpisodeCountdown = Math.max(0, Math.ceil(remaining));
            root.upNextText = "Next episode in " + root.nextEpisodeCountdown + "…  " + root.continuationLabel(root.nextEpisodeCandidate);
        } else if (remaining > 10) {
            root.nextEpisodeCountdown = 0;
        }
        root.syncLoadingCard();
        root.syncOverlay(remaining);
        root.loadNextThumb();
        root.pushNextThumb();
        root.loadIntroWindow();
        root.pushIntroWindow();
        root.attachSubtitles();
    }

    function queueWatchSave(completed) {
        if (!root.playbackId || !root.playbackTitle || root.playbackPosition < 1) return;
        root.lastWatchSaveMs = Date.now();
        var payload = {
            cmd: "watch_progress",
            provider: root.playbackProvider,
            id: root.playbackId,
            title: root.playbackTitle,
            cover: root.playbackCover,
            stype: root.playbackStype,
            season: root.playbackSeason,
            episode: root.playbackEpisode,
            position: root.playbackPosition,
            duration: root.playbackDuration,
            completed: completed === true
        };
        if (watchProgressProc.running) {
            watchProgressProc.pendingPayloads.push(payload);
            return;
        }
        root.startWatchSave(payload);
    }

    function startWatchSave(payload) {
        watchProgressProc.collected = "";
        watchProgressProc.command = [root.bridge, JSON.stringify(payload)];
        watchProgressProc.running = true;
    }

    function mergeWatchEntry(entry) {
        if (!entry || !entry.key) return;
        var updated = [entry];
        for (var i = 0; i < root.watchEntries.length; i++)
            if (root.watchEntries[i].key !== entry.key) updated.push(root.watchEntries[i]);
        root.watchEntries = updated;
        continueModel.clear();
        for (var j = 0; j < updated.length && continueModel.count < 20; j++) {
            var candidate = updated[j];
            if (candidate.completed !== true && Number(candidate.position || 0) >= 15)
                root.appendHomeItem(continueModel, candidate, candidate.provider || "stremio");
        }
    }

    function cancelNextEpisode() {
        if (!root.nextEpisodeQueued || root.nextEpisodeCancelled || root.mpvPlaylistPosition < 0) return;
        if (root.sendMpvCommands([["playlist-remove", root.mpvPlaylistPosition + 1]], "cancel-next")) {
            root.nextEpisodeCancelled = true;
            root.nextEpisodeQueued = false;
            root.nextEpisodeCountdown = 0;
            root.upNextText = "Automatic next episode cancelled";
        }
    }

    function playNextEpisodeNow() {
        if (!root.nextEpisodeQueued || root.nextEpisodeCancelled) return;
        root.sendMpvCommands([["playlist-next", "force"]], "play-next");
    }

    function warmPreparedEpisode() {
        if (!root.nextEpisodeCandidate || nextWarmupProc.running) return;
        var link = root.safeUrl(root.nextEpisodeCandidate.resourceLink || "");
        if (!link) return;
        root.nextEpisodeWarmed = true;
        nextWarmupProc.collected = "";
        nextWarmupProc.command = [root.bridge, JSON.stringify({ cmd: "warm_stream", url: link })];
        nextWarmupProc.running = true;
        root.upNextText = "Up next: " + root.continuationLabel(root.nextEpisodeCandidate) + " • warming source…";
    }

    function activateNextEpisode() {
        var stream = root.nextEpisodeCandidate;
        if (!stream) return;
        root.queueWatchSave(true);
        root.nextEpisodeTransitioned = true;
        root.playbackSeason = root.nextEpisodeSeason;
        root.playbackEpisode = root.nextEpisodeNumber;
        root.activeStream = stream;
        root.playbackPosition = 0;
        root.playbackDuration = 0;
        root.lastWatchSaveMs = 0;
        if (root.currentId === root.playbackId) {
            root.curSeason = root.playbackSeason;
            root.maxEp = root.episodeCount(root.curSeason);
            root.curEp = root.playbackEpisode;
        }
        if (stream.streamKind === "p2p") {
            root.streamHealthUrl = stream.resourceLink || "";
            root.streamHealthState = "starting";
            root.streamHealthText = "Connecting to prepared media source…";
            root.streamHealthPolls = 0;
        } else {
            root.streamHealthUrl = "";
            root.streamHealthText = "";
            root.streamHealthState = "idle";
        }
        var commands = [];
        var subtitles = stream.subtitles || [];
        for (var i = 0; i < Math.min(subtitles.length, 12); i++) {
            var subtitleUrl = root.safeUrl(subtitles[i].url || "");
            if (subtitleUrl) commands.push(["sub-add", subtitleUrl, "auto"]);
        }
        commands.push(["playlist-clear"]);
        root.sendMpvCommands(commands, "episode-transition");
        root.statusText = "Playing " + root.episodeCode(root.playbackSeason, root.playbackEpisode) + " in mpv";
        root.resetNextEpisode();
        Qt.callLater(function(){ root.prepareNextEpisode(); });
    }

    Timer {
        // Steady state is 500ms now that a poll costs an IPC round trip rather
        // than a Python interpreter start. Note this improves detection but
        // cannot make rebuffer accounting exact: a stall shorter than the
        // interval still falls between samples. observe_property over a
        // persistent mpv connection is the accurate answer.
        interval: root.metricFirstFrameMs <= 0
                    ? (root.metricStartupPolls < 100 ? 300 : 2000)
                    : 500
        repeat: true
        running: root.playing && root.mpvSocketPath !== ""
        triggeredOnStart: true
        onTriggered: {
            // Counted here rather than derived from a clock: a Date.now()
            // binding would never re-evaluate. 100 polls is about 30s of
            // waiting, after which a stream that has produced no frame is
            // not going to be helped by asking five times a second.
            if (root.playing && root.metricFirstFrameMs <= 0 && root.metricStartupPolls < 100)
                root.metricStartupPolls++;
            root.pollMpvState();
        }
    }

    Process {
        id: mpvCommandProc
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ mpvCommandProc.collected += data } }
        onExited: function(code){
            var purpose = root.mpvCommandPurpose;
            var context = root.mpvCommandContext;
            var raw = mpvCommandProc.collected;
            var resp = null;
            try { resp = JSON.parse(raw); } catch (e) {}
            if (purpose === "subtitles")
                console.log("OMACINE subtitles mpv response exit=" + code + " raw=" + raw);
            // A rejected append used to vanish silently: nothing inspected the
            // reply, so the playlist just never grew and mpv closed at the end
            // of the episode. Only failures are logged, so a healthy run is quiet.
            if (purpose === "queue-next" && !(resp && resp.ok))
                console.warn("OMACINE next: append REJECTED exit=" + code + " raw=" + raw);
            if (purpose === "queue-next" && resp && resp.ok && root.nextEpisodeCandidate) {
                root.nextEpisodeQueued = true;
                root.upNextText = "Up next: " + root.continuationLabel(root.nextEpisodeCandidate) + " • ready";
            }
            if (purpose === "subtitles") {
                root.subsFetching = "";
                var accepted = resp && resp.value ? Number(resp.value.accepted || 0) : 0;
                var expected = context ? Number(context.count || 0) : 0;
                var currentKey = root.playbackId + "|" + root.playbackSeason + "|" + root.playbackEpisode;
                if (code === 0 && resp && resp.ok && accepted === expected
                        && context && context.key === currentKey && root.playing) {
                    root.subsAttached = context.key;
                    root.statusText = accepted + " subtitle track"
                                    + (accepted === 1 ? "" : "s") + " loaded";
                } else {
                    root.subsAttached = "";
                    root.statusText = root.friendlyText((resp && resp.error)
                                    || "Could not attach subtitle tracks");
                }
            }
            root.mpvCommandPurpose = "";
            root.mpvCommandContext = null;
            Qt.callLater(function() { root.dispatchPendingSubtitle(); });
        }
    }

    Process {
        id: nextWarmupProc
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ nextWarmupProc.collected += data } }
        onExited: function(){
            if (root.nextEpisodeCandidate)
                root.upNextText = "Up next: " + root.continuationLabel(root.nextEpisodeCandidate) + " • ready";
        }
    }

    Process {
        id: watchProgressProc
        property string collected: ""
        property var pendingPayloads: []
        stdout: SplitParser { onRead: function(data){ watchProgressProc.collected += data } }
        onExited: function(){
            var resp = null;
            try { resp = JSON.parse(watchProgressProc.collected); } catch (e) {}
            if (resp && resp.ok && resp.entry) root.mergeWatchEntry(resp.entry);
            var pending = watchProgressProc.pendingPayloads.length ? watchProgressProc.pendingPayloads.shift() : null;
            if (pending) Qt.callLater(function(){ root.startWatchSave(pending); });
        }
    }

    Process {
        id: warmupProc
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ warmupProc.collected += data } }
        onExited: function(){
            try {
                var resp = JSON.parse(warmupProc.collected);
                if (resp && resp.ok && resp.value)
                    root.warmTailReady = resp.value.tailReady !== false;
            } catch (e) { }
            root._completeWarmup();
        }
    }

    Timer {
        id: warmupFallback
        interval: 1900
        repeat: false
        onTriggered: root._completeWarmup()
    }

    // Long enough that arrowing through rows does not start an engine per row,
    // short enough to still cover the pause before Play is pressed.
    Timer {
        id: streamWarmDebounce
        interval: 350
        repeat: false
        onTriggered: root.runPrefetch()
    }

    Process {
        id: streamWarmProc
        property int generation: -1
        // The link this process is warming right now. Its release must wait
        // until the range request finishes, or the request recreates the
        // engine we just removed.
        property string activeLink: ""
        property string collected: ""
        stdout: SplitParser { onRead: function(data){ streamWarmProc.collected += data } }
        onExited: function(){
            // Only a reply from the current generation may set state: an older
            // one belongs to a row the selection has already moved past.
            if (streamWarmProc.generation === root.prefetchGen) {
                var ready = false;
                try {
                    var resp = JSON.parse(streamWarmProc.collected);
                    ready = !!(resp && resp.ok && resp.value && resp.value.ready === true);
                    if (resp && resp.ok && resp.value)
                        root.warmTailReady = resp.value.tailReady !== false;
                } catch (e) { ready = false; }
                root.prefetchState = ready ? "ready" : "cold";
                // Play was pressed while this warm was still in flight and
                // adopted it rather than starting a second one, so this reply
                // is what _completeWarmup has been waiting for.
                if (root.streamConnecting && root.warmupLink !== ""
                        && root.warmupLink === root.prefetchLink)
                    root._completeWarmup();
            }
            streamWarmProc.activeLink = "";
            if (root.pendingWarmLink) {
                var next = root.pendingWarmLink;
                root.pendingWarmLink = "";
                if (next === root.prefetchLink) root.startWarm(next, root.prefetchGen);
            }
            // Only now can a link this process was warming be released.
            root.drainReleaseQueue();
        }
    }

    // Drains the release queue one engine at a time.
    Process {
        id: streamReleaseProc
        onExited: function(){ root.drainReleaseQueue(); }
    }

    // Theme song playback. Separate from the film player on purpose: it must
    // never share state with it, and killing it must never touch a stream.
    Process {
        id: themeProc
        onExited: function() { root.themePlaying = ""; }
    }

    // The backdrop clip. Separate from embeddedPlayer so it can never disturb
    // a real stream, and it carries its own audio - when a clip is playing the
    // mpv theme process stays idle rather than doubling the sound.
    MediaPlayer {
        id: themeVideoPlayer
        audioOutput: AudioOutput { id: themeVideoAudio; volume: 0.45 }
        videoOutput: themeVideoSurface
        loops: MediaPlayer.Infinite
    }

    Timer {
        id: themeVideoReveal
        repeat: false
        onTriggered: {
            if (root.view === "details" && !root.playing
                    && themeVideoPlayer.source != "") root.themeVideoShown = true;
        }
    }

    // Restarting on every slider tick would stutter, so the new volume is
    // applied once the slider settles.
    Timer {
        id: themeVolumeSettle
        interval: 450
        repeat: false
        onTriggered: {
            if (root.view !== "details" || !root.currentId) return;
            if (root.settings.themeSongs !== true) return;
            var wanted = root.currentId;
            root.stopTheme();
            root.startThemeFor(wanted);
        }
    }

    // ---- cinematic mode ----
    // Ambient lighting that follows the picture, on the laptop's own LEDs.
    // Runs only while something is playing, and only when switched on: the
    // helper restores the previous colour when it is stopped.
    readonly property string ambientTool:
        Qt.resolvedUrl("tools/omacine-ambient.py").toString().replace(/^file:\/\//, "")

    Process {
        id: ambientProc
        onExited: function() { root.ambientRunning = false; }
    }
    property bool ambientRunning: false

    function startAmbient() {
        if (root.ambientRunning || root.settings.cinematicMode !== true) return;
        ambientProc.command = ["python3", root.ambientTool, "--follow-mpv"];
        ambientProc.running = true;
        root.ambientRunning = true;
    }

    function stopAmbient() {
        // SIGTERM rather than a hard kill: the helper handles it and puts the
        // previous colour back.
        if (ambientProc.running) ambientProc.signal(15);
        root.ambientRunning = false;
    }

    function syncAmbient() {
        if (root.settings.cinematicMode === true && root.playing) root.startAmbient();
        else root.stopAmbient();
    }

    onPlayingChanged: root.syncAmbient()

    Process {
        id: mpvProc
        onExited: function() {
            root.logPlaybackMetrics("closed");
            root.clearPrefetch(false);
            root.queueWatchSave(false);
            root.playing = false;
            root.streamHealthUrl = "";
            root.streamHealthText = "";
            root.streamHealthState = "idle";
            root.streamHealthPolls = 0;
            root.clearPlaybackSession();
            root.statusText = "Player closed";
        }
    }

    AudioOutput {
        id: embeddedAudio
        volume: 1.0
    }

    MediaPlayer {
        id: embeddedPlayer
        audioOutput: embeddedAudio
        videoOutput: root.playerFullscreen ? fullscreenVideoOutput : embeddedVideoOutput
        onErrorOccurred: function(error, errorString) {
            root.statusText = "Playback error: " + errorString;
            root.embeddedPlaying = false;
        }
        onPlaybackStateChanged: {
            root.embeddedPlaying = (playbackState === MediaPlayer.PlayingState);
        }
        onPositionChanged: {
            // keep slider in sync; no-op if user dragging
        }
    }

    function normalizedHomeItem(item, fallbackProvider) {
        return {
            id: root.sanitize(item.id),
            title: root.sanitize(item.title),
            year: root.sanitize(item.year || ""),
            rating: root.sanitize(item.rating !== null && item.rating !== undefined ? String(item.rating) : "-"),
            cover: root.sanitize(item.cover || ""),
            coverPath: root.sanitize(item.cover || ""),
            backdrop: root.sanitize(item.backdrop || ""),
            backdropPath: root.sanitize(item.backdropPath || ""),
            overview: root.sanitize(item.overview || ""),
            duration: root.sanitize(item.duration || ""),
            stype: Number(item.stype || 1),
            provider: root.sanitize(item.provider || fallbackProvider),
            catalogName: root.friendlyText(item.catalogName || ""),
            progress: Number(item.progress || 0),
            position: Number(item.position || 0),
            resumeSeason: Number(item.season || 0),
            resumeEpisode: Number(item.episode || 0),
            watchKey: root.sanitize(item.key || "")
        };
    }

    // Seed the spotlight rotation. Slides without artwork are dropped so the
    // hero never cycles to an empty backdrop.
    function setHeroItems(items) {
        // The spotlight is a wide 16:9 frame. A portrait poster forced into it
        // looks broken, so landscape art wins; cover-only entries are used only
        // when nothing else is available (catalog sources carry no backdrops).
        var withBackdrop = [];
        var coverOnly = [];
        var list = items || [];
        for (var i = 0; i < list.length; i++) {
            if (!list[i]) continue;
            var candidate = root.normalizedHomeItem(list[i], "stremio");
            if (!candidate.id) continue;
            if (candidate.backdrop || candidate.backdropPath) withBackdrop.push(candidate);
            else if (candidate.cover) coverOnly.push(candidate);
        }
        root.heroItems = withBackdrop.length > 0 ? withBackdrop : coverOnly;
        root.heroIndex = 0;
        root.cacheHeroBackdrops();
    }

    // Spotlight art is large (w1280) and every rotation would otherwise refetch
    // it, so pull the whole set onto disk once and let later cycles read local
    // files.
    function cacheHeroBackdrops() {
        var urls = [];
        for (var i = 0; i < root.heroItems.length; i++) {
            var url = root.heroItems[i].backdrop;
            if (url && url.indexOf("http") === 0 && urls.indexOf(url) === -1) urls.push(url);
        }
        if (urls.length === 0) return;
        request("posters", { urls: urls }, function(resp) {
            if (!resp || !resp.ok || !resp.paths) return;
            var slides = [];
            var changed = false;
            for (var k = 0; k < root.heroItems.length; k++) {
                var slide = root.heroItems[k];
                var cached = resp.paths[slide.backdrop];
                if (!cached || slide.backdropPath === cached) { slides.push(slide); continue; }
                var copy = {};
                for (var key in slide) copy[key] = slide[key];
                copy.backdropPath = cached;
                slides.push(copy);
                changed = true;
            }
            if (changed) root.heroItems = slides;
        });
    }

    function showHeroSlide(index) {
        if (root.heroItems.length === 0) return;
        var count = root.heroItems.length;
        root.heroIndex = ((index % count) + count) % count;
    }

    function advanceHeroSlide() {
        root.showHeroSlide(root.heroIndex + 1);
    }

    function appendHomeItem(model, item, fallbackProvider) {
        model.append(root.normalizedHomeItem(item, fallbackProvider));
    }

    function libraryContains(providerName, mediaId) {
        if (!providerName || !mediaId) return false;
        for (var i = 0; i < root.libraryEntries.length; i++) {
            var entry = root.libraryEntries[i];
            if (String(entry.provider || "") === String(providerName)
                    && String(entry.id || "") === String(mediaId)) return true;
        }
        return false;
    }

    function appendLibraryItem(model, item) {
        model.append({
            mediaId: root.sanitize(item.id),
            title: root.sanitize(item.title),
            year: root.sanitize(item.year || ""),
            rating: root.sanitize(item.rating || "-"),
            cover: root.safeUrl(item.cover || ""),
            coverPath: root.safeUrl(item.cover || ""),
            stype: Number(item.stype || 1),
            provider: root.sanitize(item.provider || "stremio"),
            added: Number(item.added || 0)
        });
    }

    function libraryCount(stype) {
        var total = 0;
        for (var i = 0; i < root.libraryEntries.length; i++)
            if (Number(root.libraryEntries[i].stype || 1) === Number(stype)) total++;
        return total;
    }

    function rebuildLibraryView() {
        var wantedType = root.libraryTab === "series" ? 2 : 1;
        var query = root.libraryQuery.trim().toLowerCase();
        var filtered = [];
        for (var i = 0; i < root.libraryEntries.length; i++) {
            var entry = root.libraryEntries[i];
            if (Number(entry.stype || 1) !== wantedType) continue;
            if (query && String(entry.title || "").toLowerCase().indexOf(query) < 0) continue;
            filtered.push(entry);
        }
        filtered.sort(function(a, b) {
            if (root.librarySort === "title") {
                var at = String(a.title || "").toLowerCase();
                var bt = String(b.title || "").toLowerCase();
                return at < bt ? -1 : at > bt ? 1 : 0;
            }
            if (root.librarySort === "year") return Number(b.year || 0) - Number(a.year || 0);
            if (root.librarySort === "rating") return Number(b.rating || 0) - Number(a.rating || 0);
            return Number(b.added || 0) - Number(a.added || 0);
        });
        libraryDisplayModel.clear();
        for (var j = 0; j < filtered.length; j++) root.appendLibraryItem(libraryDisplayModel, filtered[j]);
        root.cachePostersFor([libraryDisplayModel]);
    }

    function setLibraryTab(tab) {
        if (tab !== "movie" && tab !== "series") return;
        root.libraryTab = tab;
        root.rebuildLibraryView();
    }

    function applyLibraryState(resp) {
        if (!resp || !resp.ok) return;
        root.libraryEntries = Array.isArray(resp.entries) ? resp.entries : [];
        if (root.view === "library" && root.libraryTab === "movie"
                && root.libraryCount(1) === 0 && root.libraryCount(2) > 0)
            root.libraryTab = "series";
        else if (root.view === "library" && root.libraryTab === "series"
                && root.libraryCount(2) === 0 && root.libraryCount(1) > 0)
            root.libraryTab = "movie";
        root.rebuildLibraryView();
        if (root.view === "library")
            root.statusText = root.libraryEntries.length
                            ? root.libraryEntries.length + (root.libraryEntries.length === 1 ? " saved title" : " saved titles")
                            : "Your saved movies and TV shows will appear here";
    }

    function loadLibraryState() {
        request("library_list", {}, function(resp) { root.applyLibraryState(resp); });
    }

    // ---- calendar ----
    // A month grid of the user's own shows, sourced from Cinemeta the way
    // Stremio does it: every dated episode, so a season that drops at once
    // shows every episode on the day rather than a single "next episode".
    property string calendarMonth: ""
    property var calendarCells: []
    property var calendarUpcoming: []
    property string calendarToday: ""
    property bool calendarLoading: false
    property bool calendarLoaded: false

    readonly property color calPremiere: "#C9A227"
    readonly property color calSeason:   "#4E9A4E"
    readonly property color calFinale:   "#B04444"

    property bool calendarFeedOn: false
    property string calendarFeedHost: ""
    property string calendarFeedInput: ""
    property string calendarFeedNote: ""
    property bool calendarFeedBusy: false

    function loadCalendarFeed() {
        request("calendar_feed_status", {}, function(resp) {
            if (!resp || !resp.ok) return;
            root.calendarFeedOn = resp.configured === true;
            root.calendarFeedHost = String(resp.host || "");
        });
    }

    function saveCalendarFeed(url) {
        root.calendarFeedBusy = true;
        root.calendarFeedNote = url ? "Checking the feed\u2026" : "Removing\u2026";
        request("calendar_feed_set", { url: url }, function(resp) {
            root.calendarFeedBusy = false;
            if (!resp || !resp.ok) {
                root.calendarFeedNote = root.friendlyText((resp && resp.error) || "Could not use that link");
                return;
            }
            root.calendarFeedOn = resp.configured === true;
            root.calendarFeedHost = String(resp.host || "");
            root.calendarFeedNote = resp.configured ? "Subscribed" : "Feed removed";
            root.calendarFeedInput = "";
        });
    }

    function openCalendar(force) {
        root.addonManagerOpen = false;
        root.view = "calendar";
        root.loadCalendarFeed();
        if (!root.calendarMonth) {
            var now = new Date();
            root.calendarMonth = now.getFullYear() + "-"
                               + ("0" + (now.getMonth() + 1)).slice(-2);
        }
        if (!force && root.calendarLoaded && root.calendarCells.length > 0) return;
        root.loadCalendarMonth();
    }

    function loadCalendarMonth() {
        if (root.calendarLoading) return;
        root.calendarLoading = true;
        root.busy = root.calendarCells.length === 0;
        root.busyLabel = "Building the schedule\u2026";
        var wanted = root.calendarMonth;
        request("calendar_month", { month: wanted }, function(resp) {
            root.calendarLoading = false;
            root.busy = false;
            if (wanted !== root.calendarMonth) return;
            if (!resp || !resp.ok) {
                root.statusText = root.friendlyText((resp && resp.error) || "Could not load the calendar");
                return;
            }
            root.calendarToday = String(resp.today || "");
            root.calendarUpcoming = Array.isArray(resp.upcoming) ? resp.upcoming : [];
            root.calendarCells = root.buildCalendarCells(resp.days || [], resp.first, resp.last);
            root.calendarLoaded = true;
            var total = 0;
            for (var i = 0; i < (resp.days || []).length; i++) total += resp.days[i].entries.length;
            root.statusText = total + " episodes from your shows in " + root.calendarMonthLabel();
        });
    }

    function shiftCalendarMonth(delta) {
        var parts = String(root.calendarMonth || "").split("-");
        if (parts.length !== 2) return;
        var when = new Date(Number(parts[0]), Number(parts[1]) - 1 + delta, 1);
        root.calendarMonth = when.getFullYear() + "-" + ("0" + (when.getMonth() + 1)).slice(-2);
        root.calendarLoaded = false;
        root.loadCalendarMonth();
    }

    function calendarMonthLabel() {
        var parts = String(root.calendarMonth || "").split("-");
        if (parts.length !== 2) return "";
        var when = new Date(Number(parts[0]), Number(parts[1]) - 1, 1);
        return when.toLocaleDateString(Qt.locale(), "MMMM yyyy");
    }

    // Lay the month out as whole weeks starting Monday, with blanks before the
    // first and after the last so every row has seven cells.
    function buildCalendarCells(days, first, last) {
        var byDate = ({});
        for (var i = 0; i < days.length; i++) byDate[days[i].date] = days[i].entries;
        var f = String(first).split("-");
        var start = new Date(Number(f[0]), Number(f[1]) - 1, Number(f[2]));
        var l = String(last).split("-");
        var end = new Date(Number(l[0]), Number(l[1]) - 1, Number(l[2]));
        var lead = (start.getDay() + 6) % 7;          // Monday-first
        var cells = [];
        for (var b = 0; b < lead; b++) cells.push({ date: "", entries: [], filler: true });
        for (var d = 1; d <= end.getDate(); d++) {
            var iso = start.getFullYear() + "-" + ("0" + (start.getMonth() + 1)).slice(-2)
                    + "-" + ("0" + d).slice(-2);
            cells.push({ date: iso, day: d, entries: byDate[iso] || [], filler: false });
        }
        while (cells.length % 7 !== 0) cells.push({ date: "", entries: [], filler: true });
        return cells;
    }

    function calendarAccent(entry) {
        if (entry.isFinale === true) return root.calFinale;
        if (entry.isPremiere === true) return root.calPremiere;
        if (entry.isSeasonPremiere === true) return root.calSeason;
        return "transparent";
    }

    function prettyDate(iso) {
        var parts = String(iso || "").split("-");
        if (parts.length !== 3) return String(iso || "");
        var when = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
        var today = new Date(); today.setHours(0, 0, 0, 0);
        var days = Math.round((when - today) / 86400000);
        if (days === 0) return "Today";
        if (days === 1) return "Tomorrow";
        return when.toLocaleDateString(Qt.locale(), "ddd d MMM");
    }

    function openLibrary() {
        root.addonManagerOpen = false;
        if (root.libraryTab === "movie" && root.libraryCount(1) === 0 && root.libraryCount(2) > 0)
            root.libraryTab = "series";
        else if (root.libraryTab === "series" && root.libraryCount(2) === 0 && root.libraryCount(1) > 0)
            root.libraryTab = "movie";
        root.rebuildLibraryView();
        root.view = "library";
        root.statusText = root.libraryEntries.length
                        ? root.libraryEntries.length + (root.libraryEntries.length === 1 ? " saved title" : " saved titles")
                        : "Your saved movies and TV shows will appear here";
        root.loadLibraryState();
    }

    function toggleCurrentLibrary() {
        if (!root.details || !root.currentId || root.libraryBusy) return;
        root.libraryBusy = true;
        var save = !root.currentInLibrary;
        var year = root.details.year ? String(root.details.year)
                 : root.details.releaseDate ? String(root.details.releaseDate).slice(0, 4) : "";
        var rating = root.details.imdbRatingValue !== undefined ? String(root.details.imdbRatingValue) : "";
        request("library_toggle", {
            provider: root.currentProvider,
            id: root.currentId,
            title: root.currentTitle,
            cover: root.currentCover || root.coverUrlOf(root.details),
            stype: root.isSeries ? 2 : 1,
            year: year,
            rating: rating,
            saved: save
        }, function(resp) {
            root.libraryBusy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Could not update My Library";
                return;
            }
            root.applyLibraryState(resp);
            root.statusText = save ? "Added to My Library" : "Removed from My Library";
        });
    }

    function removeLibraryItem(mediaId, title, cover, stype, provider, year, rating) {
        if (root.libraryBusy) return;
        root.libraryBusy = true;
        request("library_toggle", {
            provider: provider,
            id: mediaId,
            title: title,
            cover: cover,
            stype: stype,
            year: year,
            rating: rating,
            saved: false
        }, function(resp) {
            root.libraryBusy = false;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Could not remove this title";
                return;
            }
            root.applyLibraryState(resp);
            root.statusText = "Removed “" + title + "” from My Library";
        });
    }

    // Drop a title from Continue Watching. The bridge keys entries by a hash of
    // provider+id+season+episode, which normalizedHomeItem carries as watchKey.
    function removeWatchEntry(item) {
        if (!item) return;
        var key = String(item.watchKey || "");
        var title = String(item.title || "this title");
        if (!key) { root.statusText = "Cannot remove " + title + " — no saved progress key"; return; }
        request("watch_remove", { key: key }, function(resp) {
            if (!resp || !resp.ok) {
                root.statusText = root.friendlyText((resp && resp.error) || "Could not remove " + title);
                return;
            }
            root.statusText = "Removed \u201C" + title + "\u201D from Continue Watching";
            root.loadWatchState();
        });
    }

    function loadWatchState() {
        request("watch_list", {}, function(resp) {
            if (!resp || !resp.ok) return;
            root.watchEntries = Array.isArray(resp.entries) ? resp.entries : [];
            continueModel.clear();
            var continuing = Array.isArray(resp.continueWatching) ? resp.continueWatching : [];
            for (var i = 0; i < continuing.length; i++)
                root.appendHomeItem(continueModel, continuing[i], continuing[i].provider || "stremio");
        });
    }

    // "More like this" on the details page. Entries come from TMDB and are
    // already provider-neutral, so they open exactly like any other card.
    function fillRelatedRail(items) {
        detailRelatedModel.clear();
        var list = items || [];
        for (var i = 0; i < list.length; i++) {
            if (!list[i] || !list[i].id) continue;
            root.appendHomeItem(detailRelatedModel, list[i], "stremio");
        }
        if (detailRelatedModel.count > 0) root.cachePostersFor([detailRelatedModel]);
    }

    function fillCinematicModel(model, items) {
        model.clear();
        var values = Array.isArray(items) ? items : [];
        for (var i = 0; i < values.length; i++) root.appendHomeItem(model, values[i], "stremio");
    }

    function loadCinematicHome(force) {
        root.addonManagerOpen = false;
        root.view = "home";
        root.loadWatchState();
        root.loadLibraryState();
        if (!root.tmdbConfigured) {
            root.statusText = "Connect TMDB in Sources for cinematic discovery";
            if (cinematicTrendingModel.count === 0) root.loadTvHome(force, false, "home");
            return;
        }
        if (!force && root.cinematicHomeLoaded && cinematicTrendingModel.count > 0) {
            root.statusText = "Your cinematic home";
            return;
        }
        if (root.cinematicHomeLoading) return;
        root.cinematicHomeLoading = true;
        // Stale-while-revalidate: paint the last known feed immediately, then
        // refresh behind it. Only an empty snapshot shows a spinner.
        if (!root.cinematicHomeLoaded) root.loadHomeSnapshot();
        root.busy = !root.cinematicHomeLoaded;
        root.busyLabel = "Curating OmaCine…";
        request("tmdb_home", {}, function(resp) {
            root.cinematicHomeLoading = false;
            root.busy = false;
            if (!resp || !resp.ok || !resp.sections) {
                if (root.cinematicHomeLoaded) {
                    root.statusText = "Showing your last saved home — TMDB is unreachable";
                    return;
                }
                root.statusText = root.friendlyText((resp && resp.error) || "Could not load cinematic discovery");
                root.loadTvHome(true, false, "home");
                return;
            }
            root.applyCinematicHome(resp);
            root.statusText = "Trending, new and popular picks powered by TMDB";
        });
    }

    // Shared by the instant snapshot paint and the live refresh so both take
    // exactly the same path into the models.
    function applyCinematicHome(payload) {
        if (!payload || !payload.sections) return false;
        root.setHeroItems(payload.heroes && payload.heroes.length ? payload.heroes
                                                                  : (payload.hero ? [payload.hero] : []));
        root.fillCinematicModel(cinematicTrendingModel, payload.sections.trending);
        root.fillCinematicModel(cinematicMovieModel, payload.sections.movies);
        root.fillCinematicModel(cinematicTvModel, payload.sections.television);
        root.fillCinematicModel(cinematicNewModel, payload.sections.newMovies);
        root.fillCinematicModel(cinematicAiringModel, payload.sections.airing);
        root.cinematicHomeLoaded = cinematicTrendingModel.count > 0;
        root.cachePostersFor([cinematicTrendingModel, cinematicMovieModel, cinematicTvModel,
                              cinematicNewModel, cinematicAiringModel, continueModel]);
        return root.cinematicHomeLoaded;
    }

    function loadHomeSnapshot() {
        request("home_snapshot", {}, function(resp) {
            if (!resp || !resp.ok || resp.cached !== true) return;
            if (root.cinematicHomeLoaded) return;   // live data already won the race
            if (root.applyCinematicHome(resp)) {
                root.busy = false;
                root.statusText = "Your cinematic home";
            }
        });
    }

    function loadTvHome(force, append, targetView) {
        if (root.homeLoading || root.homeAppending) return;
        append = append === true;
        var destination = targetView || "discover";
        if (!force && !append && root.homeProvider === "stremio" && homeModel.count > 0) {
            root.view = destination;
            root.loadWatchState();
            return;
        }
        if (!append) root.discoveryPage = 1;
        root.homeLoading = !append;
        root.homeAppending = append;
        root.busy = !append;
        root.busyLabel = append ? "" : "Loading TV & Movies…";
        request("homepage", {
            provider: "stremio",
            mediaType: root.discoveryType,
            catalogKey: root.discoveryCatalogKey,
            genre: root.discoveryGenre,
            year: root.discoveryYear,
            sort: root.discoverySort,
            perPage: 80,
            page: root.discoveryPage
        }, function(resp) {
            root.homeLoading = false;
            root.homeAppending = false;
            root.busy = false;
            root.view = destination;
            if (!resp || !resp.ok) {
                root.statusText = (resp && resp.error) || "Could not load TV & Movies";
                return;
            }
            root.discoveryCatalogs = Array.isArray(resp.catalogs) ? resp.catalogs : [];
            if (!append) homeModel.clear();
            var items = Array.isArray(resp.items) ? resp.items : [];
            var existing = {};
            for (var e = 0; e < homeModel.count; e++) existing[String(homeModel.get(e).id || "")] = true;
            var added = 0;
            for (var i = 0; i < items.length; i++) {
                var itemId = String(items[i].id || "");
                if (!itemId || existing[itemId]) continue;
                existing[itemId] = true;
                root.appendHomeItem(homeModel, items[i], "stremio");
                added++;
            }
            root.discoveryHasMore = resp.hasMore === true && (!append || added > 0);
            root.homeProvider = "stremio";
            var label = root.discoverySort === "new" ? "New releases" : root.discoverySort === "rating" ? "Top rated" : "Popular now";
            root.statusText = homeModel.count ? label + " • " + homeModel.count + " titles" : "No catalog titles match these filters";
            if (destination === "home" && homeModel.count > 0) {
                // Catalog entries have no backdrop and usually no overview, so
                // they must not replace spotlight slides that TMDB already
                // supplied — that is what left the hero showing a stretched
                // poster with no plot after navigating away and back.
                var fallbackSlides = [];
                for (var s = 0; s < Math.min(6, homeModel.count); s++)
                    fallbackSlides.push(homeModel.get(s));
                if (root.heroItems.length === 0) root.setHeroItems(fallbackSlides);
                if (cinematicTrendingModel.count === 0) {
                    for (var h = 0; h < Math.min(20, homeModel.count); h++)
                        root.appendHomeItem(cinematicTrendingModel, homeModel.get(h), "stremio");
                }
            }
            root.loadWatchState();
            root.cachePosters(homeModel);
        });
    }

    function loadMoreTv() {
        if (root.homeLoading || root.homeAppending || !root.discoveryHasMore) return;
        root.discoveryPage++;
        root.loadTvHome(true, true, "discover");
    }

    function setDiscoveryFilter(kind, value) {
        if (kind === "type") root.discoveryType = value;
        else if (kind === "sort") root.discoverySort = value;
        else if (kind === "genre") root.discoveryGenre = value;
        else if (kind === "year") root.discoveryYear = value;
        else if (kind === "catalog") root.discoveryCatalogKey = value;
        root.discoveryPage = 1;
        root.discoveryHasMore = false;
        root.openDiscover(true);
    }

    function catalogOptions() {
        var options = [{ value: "", label: "All catalogs" }];
        for (var i = 0; i < root.discoveryCatalogs.length; i++)
            options.push({ value: String(root.discoveryCatalogs[i].key || ""), label: root.friendlyText(root.discoveryCatalogs[i].name || "Service") });
        return options;
    }

    function loadHome(force) {
        root.loadLibraryState();
        if (root.provider === "stremio") root.loadCinematicHome(force);
    }


    function goHome() {
        root.loadCinematicHome(false);
    }

    function openDiscover(force) {
        root.addonManagerOpen = false;
        root.view = "discover";
        root.statusText = "Browse movies and TV shows by type, year, genre and catalog";
        root.loadTvHome(force === true, false, "discover");
    }

    function openSources() {
        root.addonManagerOpen = true;
        root.loadCacheUsage();
        root.statusText = "Manage discovery metadata and playback sources";
        root.loadAddons();
    }


    function backToGrid() {
        root.view = "grid";
    }

    function backFromDetails() {
        // Every title is provider "stremio" now that the scrapers are gone, so
        // the old provider test was always true and sent Back to the search
        // grid from everywhere - a blank page unless you had actually searched.
        // Honour the surface recorded on the way in, and only return to the
        // grid when it still holds results.
        if (root.detailsReturnView === "library") root.openLibrary();
        else if (root.detailsReturnView === "calendar") root.openCalendar(false);
        else if (root.detailsReturnView === "discover") root.openDiscover(false);
        else if (root.detailsReturnView === "grid" && resultModel.count > 0) root.backToGrid();
        else root.goHome();
    }

    function refreshCurrent() {
        if (root.view === "calendar") root.openCalendar(true);
        else if (root.view === "home") root.loadCinematicHome(true);
        else if (root.view === "discover") root.openDiscover(true);
        else if (root.view === "library") root.openLibrary();
        else if (root.view === "grid") {
            root.doSearch();
        }
        else if (root.view === "details" && root.currentId) {
            // Reload straight from the open title. The old code searched
            // resultModel then homeModel for a matching row and fell through to
            // the search grid when neither had one - which is every title
            // opened from a cinematic rail, Continue Watching or More Like
            // This, so refreshing those emptied the page.
            root.openItem({
                id: root.currentId,
                title: root.currentTitle,
                cover: root.currentCover,
                provider: root.currentProvider,
                resumeSeason: root.curSeason,
                resumeEpisode: 1
            });
        } else root.loadHome(true);
    }

    function stopEmbedded() {
        if (embeddedPlayer) {
            embeddedPlayer.stop();
            embeddedPlayer.source = "";
        }
        root.embeddedPlaying = false;
        root.playerUrl = "";
        root.playerFullscreen = false;
    }

    // ---------------- open/close wiring (same contract as pacman) ----------------
    function openFromHotkey() {
        // Show first, then load. Data calls used to run ahead of show(), so a
        // single exception in any of them meant clicking the bar icon silently
        // did nothing. The panel must never depend on a fetch succeeding.
        root.controller.show();
        Qt.callLater(function() {
            if (root.opened) searchField.forceActiveFocus();
        });
        try {
            if (!root.cinematicHomeLoaded && !root.cinematicHomeLoading) root.loadCinematicHome(false);
            root.loadWatchState();
            root.loadLibraryState();
            root.loadTmdbStatus();
            // Without this mdbConfigured stays false until Settings is opened,
            // and the ratings lookup silently bails on every title.
            root.loadMdbStatus();
            root.loadSettings();
        } catch (e) {
            root.statusText = "Could not refresh: " + e;
        }
    }
    onPlayerFullscreenChanged: {
        if (root.view !== "player" || !embeddedPlayer.source) return;
        var wasPlaying = embeddedPlayer.playbackState === MediaPlayer.PlayingState;
        var pos = embeddedPlayer.position;
        Qt.callLater(function() {
            embeddedPlayer.position = pos;
            if (wasPlaying) embeddedPlayer.play();
            else embeddedPlayer.pause();
        });
    }

    function close() {
        root.stopTheme();
        // close() hides the controller without changing root.view, so the
        // onViewChanged cleanup never fires here: release explicitly or a
        // prefetched swarm keeps running behind a closed panel.
        if (!root.playing) root.clearPrefetch(true);
        // Lighting belongs to OmaCine being open, not to the process outliving
        // it: closing the panel puts the LEDs back however they were.
        root.stopAmbient();
        if (root.view === "player") { root.stopEmbedded(); root.playerFullscreen = false; }
        root.controller.hide();
    }
    function toggle() {
        if (root.opened) root.close();
        else root.openFromHotkey();
    }
    function closeForPopoutSwitch() { root.close(); }
    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction);
        return false;
    }

    // ---------------- UI ----------------
    ListModel { id: resultModel }
    ListModel { id: homeModel }
    ListModel { id: continueModel }
    ListModel { id: cinematicTrendingModel }
    ListModel { id: cinematicMovieModel }
    ListModel { id: cinematicTvModel }
    ListModel { id: cinematicNewModel }
    ListModel { id: cinematicAiringModel }
    ListModel { id: libraryDisplayModel }
    ListModel { id: detailRelatedModel }
    ListModel { id: addonModel }
    ListModel { id: resolverModel }

    // Spotlight rotation. Only ticks while the home view is actually on
    // screen, and holds still while the pointer is over the hero so a title
    // never changes out from under a click.
    Timer {
        id: heroRotationTimer
        interval: Math.max(3, Number(root.settings.spotlightSeconds)) * 1000
        repeat: true
        running: root.opened && root.view === "home" && root.settings.spotlightRotate === true
                 && !root.heroHovered && root.heroItems.length > 1
        onTriggered: root.advanceHeroSlide()
    }

    Component {
        id: libraryCardDelegate
        Rectangle {
            required property string mediaId
            required property string title
            required property string year
            required property string rating
            required property string cover
            required property string coverPath
            required property int stype
            required property string provider
            required property double added
            width: Math.round(160 * panel.uiScale)
            height: Math.round(226 * panel.uiScale)
            radius: Style.cornerRadius
            color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
            border.width: libraryCardMouse.containsMouse ? 1 : 0
            border.color: Color.accent
            clip: true
            Column {
                anchors.fill: parent
                anchors.margins: 5
                spacing: 4
                Rectangle {
                    width: parent.width
                    height: parent.height - 42
                    radius: Style.cornerRadius
                    color: Qt.darker(Color.foreground, 2.2)
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: root.imageSource(coverPath) || root.imageSource(cover)
                        // Decode at draw size; full-resolution posters are what stall scrolling.
                        sourceSize.width: Math.round(width)
                        sourceSize.height: Math.round(height)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: source !== ""
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: cover === ""
                        text: stype === 2 ? "󰒋" : ""
                        font.family: root.uiFont
                        font.pixelSize: root.fs(28)
                        color: Qt.darker(Color.foreground, 1.3)
                    }
                }
                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: title
                    elide: Text.ElideRight
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: true
                    color: Color.foreground
                }
                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: (year || "–") + (rating && rating !== "-" ? ("  ★ " + rating) : "")
                    elide: Text.ElideRight
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption - 2)
                    color: Qt.darker(Color.foreground, 1.4)
                }
            }
            MouseArea {
                id: libraryCardMouse
                anchors.fill: parent
                hoverEnabled: true
                // Clicks only: a delegate that consumes scroll gestures starves
                // the surrounding Flickable of the release event.
                scrollGestureEnabled: false
                cursorShape: Qt.PointingHandCursor
                enabled: !root.busy
                onClicked: root.openItem({
                    id: mediaId, title: title, year: year, rating: rating,
                    cover: cover, stype: stype, provider: provider
                })
            }
            Button {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 7
                z: 3
                text: "×"
                tooltipText: "Remove from My Library"
                enabled: !root.libraryBusy
                fontSize: root.fs(Style.font.body)
                horizontalPadding: 8
                verticalPadding: 3
                onClicked: root.removeLibraryItem(mediaId, title, cover, stype, provider, year, rating)
            }
        }
    }

    Timer {
        id: suggestTimer
        interval: 350
        repeat: false
        onTriggered: {
            var q = searchField.text.trim();
            if (q.length < 2) { suggestionModel.clear(); return; }
            root.suggestGen++;
            var gen = root.suggestGen;
            var suggestProvider = root.provider;
            request("suggest", { q: q, provider: suggestProvider }, function(resp) {
                if (gen !== root.suggestGen) return;
                if (suggestProvider !== root.provider) return;
                var list = (resp && resp.ok && resp.suggestions) ? resp.suggestions : [];
                suggestionModel.clear();
            for (var i = 0; i < list.length && i < 6; i++)
                suggestionModel.append({ name: root.sanitize(list[i].name) });
            });
        }
    }
    ListModel { id: suggestionModel }

    FloatingWindow {
        id: panel
        title: "OmaCine"
        visible: root.opened
        color: Color.popups.background
        // Sized from the display, not a fixed box. uiScale grows the contents on
        // larger screens, so a hardcoded window used to show *less* the better
        // the monitor was.
        // Deliberately taller than it is wide-ish: a 16:9 backdrop needs height,
        // and every extra pixel of width raises the height needed to show the
        // whole frame. These fractions keep ~80% of a backdrop visible while
        // still leaving a full rail above the fold.
        implicitWidth: Math.round(Math.max(720, Math.min(1400, screenW * 0.58)))
        implicitHeight: Math.round(Math.max(520, Math.min(1080, screenH * 0.88)))
        minimumSize: Qt.size(640, 480)

        // Dynamic sizing: fractions of screen resolution
        readonly property real screenW: screen ? screen.width : (Quickshell.screens.length > 0 ? Quickshell.screens[0].width : 1920)
        readonly property real screenH: screen ? screen.height : (Quickshell.screens.length > 0 ? Quickshell.screens[0].height : 1080)
        readonly property bool isSmallScreen: screenW > 0 && screenW < 1366
        readonly property bool isLargeScreen: screenW >= 1920
        readonly property real uiScale: Math.min(1.4, Math.max(0.9, screenW / 1920))

        onVisibleChanged: {
            if (!visible && root.opened) root.close();
        }

        ColumnLayout {
            id: mainColumn
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

        // header — refined, responsive
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    spacing: 8
                    Text { text: ""; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.title); color: Color.accent }
                    Text { text: "OmaCine"; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.title); font.bold: true; color: Color.foreground }
                    Rectangle { width: 1; height: 18; color: Color.foreground; opacity: 0.12; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                    Text {
                        text: root.view === "player" ? "Player" : root.view === "details" ? "Showcase" : root.view === "grid" ? "Search" : root.view === "library" ? "Library" : root.view === "discover" ? "Discover" : "Home"
                        font.family: root.uiFont; font.pixelSize: root.fs(Style.font.bodySmall); color: Qt.darker(Color.foreground, 1.25); font.capitalization: Font.AllUppercase
                    }
                    Item { Layout.fillWidth: true }
                    // busy indicator inline
                    RowLayout {
                        spacing: 6; visible: root.busy || root.playing
                        Rectangle { width: 8; height: 8; radius: 4; color: Color.accent; opacity: 0.9; visible: root.busy
                            SequentialAnimation on opacity { running: root.busy; loops: Animation.Infinite; NumberAnimation { from: 0.4; to: 1.0; duration: 700 } NumberAnimation { from: 1.0; to: 0.4; duration: 700 } }
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: root.busy ? root.busyLabel : "Playing"
                            font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption); color: Color.accent
                        }
                    }
                }
                Text {
                    textFormat: Text.PlainText
                    text: root.statusText
                    font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 1); color: Qt.darker(Color.foreground, 1.35)
                    elide: Text.ElideRight; Layout.fillWidth: true; maximumLineCount: 1
                }
            }
            Button {
                text: "\u21bb"
                tooltipText: "Refresh"
                fontSize: root.fs(Style.font.body)
                horizontalPadding: 10
                verticalPadding: 5
                onClicked: root.refreshCurrent()
            }
            Button {
                text: "✕"
                tooltipText: "Close"
                fontSize: root.fs(Style.font.body)
                horizontalPadding: 12
                verticalPadding: 6
                onClicked: root.close()
            }
        }
        PanelSeparator { Layout.fillWidth: true; opacity: 0.5 }

        // OmaCine primary navigation — content first; sources stay secondary.
        RowLayout {
            id: primaryNav
            Layout.fillWidth: true
            spacing: 8
            Button {
                text: "Home"
                iconText: "\uf015"
                selected: root.view === "home" && !root.addonManagerOpen
                onClicked: root.goHome()
            }
            Button {
                text: "Discover"
                iconText: "\uf005"
                selected: root.view === "discover" && !root.addonManagerOpen
                onClicked: root.openDiscover(false)
            }
            Button {
                text: "Library" + (root.libraryEntries.length ? (" (" + root.libraryEntries.length + ")") : "")
                iconText: "\uf02e"
                selected: root.view === "library" && !root.addonManagerOpen
                enabled: !root.libraryBusy
                onClicked: root.openLibrary()
            }
            Button {
                text: "Calendar"
                iconText: "\uf133"
                selected: root.view === "calendar" && !root.addonManagerOpen
                onClicked: root.openCalendar(false)
            }
            Button {
                text: "Cinematic"
                iconText: "\uf0eb"
                tooltipText: root.settings.cinematicMode === true
                    ? "Ambient lighting follows the picture while you watch"
                    : "Light the keyboard and underglow to match what is playing"
                selected: root.settings.cinematicMode === true
                onClicked: {
                    var next = root.settings.cinematicMode !== true;
                    root.updateSetting("cinematicMode", next);
                    // updateSetting is optimistic, so the local value is already
                    // correct and this can act on it immediately.
                    root.syncAmbient();
                    root.statusText = next
                        ? "Cinematic mode on \u2014 lighting follows playback"
                        : "Cinematic mode off";
                }
            }
            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "Search OmaCine…"
                onAccepted: root.doSearch()
                onTextChanged: root.debounceSuggest()
                Keys.onEscapePressed: function(event) {
                    if (searchField.text.length > 0) {
                        searchField.clear();
                        suggestionModel.clear();
                    } else {
                        suggestionModel.clear();
                        root.close();
                    }
                    event.accepted = true;
                }
            }
            Button {
                text: "Search"
                iconText: "\uf002"
                selected: true
                onClicked: root.doSearch()
            }
            Button {
                text: root.addonManagerOpen ? "Close Settings" : "Settings"
                selected: root.addonManagerOpen
                onClicked: {
                    root.addonManagerOpen = !root.addonManagerOpen;
                    if (root.addonManagerOpen) { root.loadAddons(); root.loadSettings(); }
                    else root.goHome();
                }
            }
        }

        // Settings. Add-on manifests live in ~/.config/omamovie/addons.json;
        // interface preferences in ~/.config/omamovie/settings.json.
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.addonManagerOpen
            spacing: 6

            // ---- section tabs ----
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Add-ons"
                    iconText: "\uf1e6"
                    selected: root.settingsSection === "addons"
                    onClicked: { root.settingsSection = "addons"; root.loadAddons(); }
                }
                Button {
                    text: "Interface"
                    iconText: "\uf013"
                    selected: root.settingsSection === "interface"
                    onClicked: { root.settingsSection = "interface"; root.loadSettings(); }
                }
                Item { Layout.fillWidth: true }
                Button {
                    text: "Restore defaults"
                    visible: root.settingsSection === "interface"
                    enabled: !root.settingsBusy
                    fontSize: root.fs(Style.font.caption)
                    onClicked: root.resetSettings()
                }
            }

            PanelSeparator { Layout.fillWidth: true; opacity: 0.4 }

            // ---- interface section ----
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.settingsSection === "interface"
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    text: "Text size"
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: true
                    color: Color.accent
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Interface font"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.foreground
                    }
                    Item { Layout.fillWidth: true }
                    Dropdown {
                        width: 190
                        showLabel: false
                        value: root.uiFont
                        options: root.fontOptions()
                        enabled: !root.settingsBusy
                        onChanged: function(nextValue) { root.updateSetting("uiFontFamily", nextValue) }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "Titles, descriptions and names use this. Stream specs and rating "
                          + "figures stay monospaced, where aligned columns are the point."
                    wrapMode: Text.WordWrap
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption - 1)
                    color: Qt.darker(Color.foreground, 1.5)
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Interface text scale"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.foreground
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: Math.round(root.textScale * 100) + "%"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.accent
                    }
                }

                PanelSlider {
                    Layout.fillWidth: true
                    bar: root.bar
                    minimum: 0.85; maximum: 1.6
                    value: root.textScale
                    enabled: !root.settingsBusy
                    onMoved: function(v) { root.updateSetting("textScale", Math.round(v * 20) / 20); }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: root.settings.themeSongs === true
                    Text {
                        text: "Theme song volume"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.foreground
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: Number(root.settings.themeVolume) === 0
                            ? "muted" : Number(root.settings.themeVolume) + "%"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.accent
                    }
                }

                PanelSlider {
                    Layout.fillWidth: true
                    visible: root.settings.themeSongs === true
                    bar: root.bar
                    minimum: 0; maximum: 100
                    value: Number(root.settings.themeVolume)
                    enabled: !root.settingsBusy
                    onMoved: function(v) {
                        root.updateSetting("themeVolume", Math.round(v / 5) * 5);
                        themeVolumeSettle.restart();
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "Scales only OmaCine's text. The rest of the Omarchy shell keeps "
                          + "its own font size, set with “omarchy font”."
                    wrapMode: Text.WordWrap
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption - 1)
                    color: Qt.darker(Color.foreground, 1.45)
                }

                PanelSeparator { Layout.fillWidth: true; opacity: 0.3 }

                // ---- episode calendar feed ----
                Text {
                    Layout.fillWidth: true
                    text: "Episode calendar feed"
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: true
                    color: Color.accent
                }
                Text {
                    Layout.fillWidth: true
                    text: root.calendarFeedOn
                        ? "Subscribed to " + root.calendarFeedHost + ". Its shows appear in Calendar "
                          + "alongside your library."
                        : "Paste an iCalendar (.ics) link \u2014 for example the "
                          + "\u201Cgenerate_ics\u201D link from pogdesign \u2014 to track shows you "
                          + "follow there. The link is a private key, so it is stored readable only by you."
                    wrapMode: Text.WordWrap
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption - 1)
                    color: Qt.darker(Color.foreground, 1.45)
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    TextField {
                        Layout.fillWidth: true
                        placeholderText: "https://www.pogdesign.co.uk/cat/generate_ics/\u2026"
                        text: root.calendarFeedInput
                        echoMode: TextInput.Password
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        onTextChanged: root.calendarFeedInput = text
                        onAccepted: root.saveCalendarFeed(text.trim())
                    }
                    Button {
                        text: root.calendarFeedBusy ? "\u2026" : "Subscribe"
                        enabled: !root.calendarFeedBusy && root.calendarFeedInput.trim() !== ""
                        fontSize: root.fs(Style.font.caption)
                        onClicked: root.saveCalendarFeed(root.calendarFeedInput.trim())
                    }
                    Button {
                        text: "Remove"
                        visible: root.calendarFeedOn
                        enabled: !root.calendarFeedBusy
                        fontSize: root.fs(Style.font.caption)
                        onClicked: root.saveCalendarFeed("")
                    }
                    Text {
                        visible: root.calendarFeedNote !== ""
                        text: root.calendarFeedNote
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption - 1)
                        color: Color.accent
                    }
                }

                PanelSeparator { Layout.fillWidth: true; opacity: 0.3 }

                // ---- storage ----
                Text {
                    Layout.fillWidth: true
                    text: "Storage"
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: true
                    color: Color.accent
                }

                Repeater {
                    model: root.cacheUsage
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.preferredWidth: Math.round(96 * panel.uiScale)
                            text: modelData.name
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption - 1)
                            color: Color.foreground
                        }
                        // A bar makes "how close to full" readable at a glance;
                        // caches with no size budget just show their size.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.round(8 * panel.uiScale)
                            radius: height / 2
                            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
                            Rectangle {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                height: parent.height
                                radius: height / 2
                                visible: Number(modelData.budget) > 0
                                width: {
                                    var b = Number(modelData.budget) || 0;
                                    if (b <= 0) return 0;
                                    return Math.min(1, Number(modelData.bytes) / b) * parent.width;
                                }
                                color: Number(modelData.bytes) > Number(modelData.budget)
                                     ? "#D05050" : Color.accent
                            }
                        }
                        Text {
                            Layout.preferredWidth: Math.round(120 * panel.uiScale)
                            horizontalAlignment: Text.AlignRight
                            text: root.fmtBytes(modelData.bytes)
                                + (Number(modelData.budget) > 0
                                   ? " / " + root.fmtBytes(modelData.budget) : "")
                            font.family: root.dataFont
                            font.pixelSize: root.fs(Style.font.caption - 2)
                            color: Qt.darker(Color.foreground, 1.4)
                        }
                        Button {
                            text: "Clear"
                            enabled: !root.cacheBusy && modelData.name !== "torrent"
                            tooltipText: modelData.name === "torrent"
                                ? "The streaming server manages this one"
                                : "Delete everything in this cache"
                            fontSize: root.fs(Style.font.caption - 1)
                            onClicked: root.clearCache(modelData.name)
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Poster cache"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.foreground
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: Number(root.settings.cachePostersMB) + " MB"
                        font.family: root.dataFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.accent
                    }
                }
                PanelSlider {
                    Layout.fillWidth: true
                    bar: root.bar
                    minimum: 50; maximum: 2000
                    value: Number(root.settings.cachePostersMB)
                    enabled: !root.settingsBusy
                    onMoved: function(v) { root.updateSetting("cachePostersMB", Math.round(v / 25) * 25); }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Theme song cache"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.foreground
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: Number(root.settings.cacheThemesMB) + " MB"
                        font.family: root.dataFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.accent
                    }
                }
                PanelSlider {
                    Layout.fillWidth: true
                    bar: root.bar
                    minimum: 100; maximum: 4000
                    value: Number(root.settings.cacheThemesMB)
                    enabled: !root.settingsBusy
                    onMoved: function(v) { root.updateSetting("cacheThemesMB", Math.round(v / 50) * 50); }
                }

                Text {
                    Layout.fillWidth: true
                    text: "Budgets are enforced by each cache's own sweep, so lowering one "
                          + "frees space at its next prune rather than immediately \u2014 use "
                          + "Clear for that. The torrent cache belongs to the streaming "
                          + "server and is shown here for the full picture."
                    wrapMode: Text.WordWrap
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption - 1)
                    color: Qt.darker(Color.foreground, 1.45)
                }

                PanelSeparator { Layout.fillWidth: true; opacity: 0.3 }

                Text {
                    Layout.fillWidth: true
                    text: "Artwork and motion"
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: true
                    color: Color.accent
                }

                Repeater {
                    model: [
                        { key: "backdropOpacity", label: "Details backdrop strength",
                          hint: "How visible the show artwork is behind the details page" },
                        { key: "backdropDim",     label: "Details readability tint",
                          hint: "Higher values darken the artwork so text stays legible" },
                        { key: "heroOverlay",     label: "Spotlight tint",
                          hint: "How much the home spotlight artwork is dimmed" }
                    ]
                    delegate: ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: modelData.label
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption)
                                color: Color.foreground
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: Math.round(Number(root.settings[modelData.key]) * 100) + "%"
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption)
                                color: Color.accent
                            }
                        }
                        PanelSlider {
                            Layout.fillWidth: true
                            bar: root.bar
                            minimum: 0; maximum: 1
                            value: Number(root.settings[modelData.key])
                            enabled: !root.settingsBusy
                            onMoved: function(v) { root.updateSetting(modelData.key, v); }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.hint
                            wrapMode: Text.WordWrap
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption - 1)
                            color: Qt.darker(Color.foreground, 1.45)
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text: (root.settings.spotlightRotate === true ? "\u2713  " : "") + "Rotate spotlight"
                        tooltipText: "Cycle the home spotlight through trending titles"
                        selected: root.settings.spotlightRotate === true
                        enabled: !root.settingsBusy
                        onClicked: root.updateSetting("spotlightRotate", root.settings.spotlightRotate !== true)
                    }
                    Button {
                        text: (root.settings.railHoverPreview === true ? "\u2713  " : "") + "Preload on hover"
                        tooltipText: "Fetch details and streams while you hover a card"
                        selected: root.settings.railHoverPreview === true
                        enabled: !root.settingsBusy
                        onClicked: root.updateSetting("railHoverPreview", root.settings.railHoverPreview !== true)
                    }
                    Button {
                        text: (root.settings.prefetchStreams === true ? "\u2713  " : "") + "Prepare stream"
                        tooltipText: "Connect to the chosen stream's sources while you are still "
                                   + "picking, so Play starts sooner. Costs up to a megabyte for "
                                   + "a stream you do not end up watching."
                        selected: root.settings.prefetchStreams === true
                        enabled: !root.settingsBusy
                        onClicked: {
                            var next = root.settings.prefetchStreams !== true;
                            root.updateSetting("prefetchStreams", next);
                            // Turning it off should also hand back the engine
                            // a prefetch has already started, not just stop
                            // starting new ones.
                            if (!next) root.clearPrefetch(true);
                        }
                    }
                    Button {
                        text: (root.settings.themeVideo === true ? "\u2713  " : "") + "Video backdrops"
                        tooltipText: "Fade the theme's video in behind a title's page, Netflix style"
                        selected: root.settings.themeVideo === true
                        enabled: !root.settingsBusy && root.settings.themeSongs === true
                        onClicked: {
                            root.updateSetting("themeVideo", root.settings.themeVideo !== true);
                            if (root.view === "details" && root.currentId) {
                                var again = root.currentId;
                                root.stopTheme();
                                root.startThemeFor(again);
                            }
                        }
                    }
                    Button {
                        text: (root.settings.themeSongs === true ? "\u2713  " : "") + "Theme songs"
                        tooltipText: "Play a show or film's theme from ThemerrDB while you browse its page"
                        selected: root.settings.themeSongs === true
                        enabled: !root.settingsBusy
                        onClicked: {
                            var next = root.settings.themeSongs !== true;
                            root.updateSetting("themeSongs", next);
                            if (!next) root.stopTheme();
                            else if (root.view === "details" && root.currentId) root.startThemeFor(root.currentId);
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: root.settings.spotlightRotate === true
                        text: "every " + Number(root.settings.spotlightSeconds) + "s"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Qt.darker(Color.foreground, 1.3)
                    }
                }

                PanelSlider {
                    Layout.fillWidth: true
                    visible: root.settings.spotlightRotate === true
                    bar: root.bar
                    minimum: 3; maximum: 60
                    value: Number(root.settings.spotlightSeconds)
                    enabled: !root.settingsBusy
                    onMoved: function(v) { root.updateSetting("spotlightSeconds", Math.round(v)); }
                }
            }

            // ---- add-ons section ----
            RowLayout {
                Layout.fillWidth: true
                visible: root.settingsSection === "addons"
                spacing: 8
                Item { Layout.fillWidth: true }
                Text {
                    text: "This only changes global search; Home and Discover remain unified."
                    elide: Text.ElideRight
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption - 2)
                    color: Qt.darker(Color.foreground, 1.45)
                }
            }
            PanelSeparator {
                visible: root.settingsSection === "addons"; Layout.fillWidth: true; opacity: 0.5 }

            RowLayout {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: addonManifestField
                    Layout.fillWidth: true
                    placeholderText: "Paste authorized https://…/manifest.json"
                    enabled: !root.addonBusy
                    onAccepted: root.addManifest()
                    Keys.onEscapePressed: function(event) {
                        addonManifestField.clear();
                        event.accepted = true;
                    }
                }
                Button {
                    text: root.addonBusy ? "Checking …" : "Add manifest"
                    selected: true
                    enabled: !root.addonBusy && addonManifestField.text.trim().length > 0
                    onClicked: root.addManifest()
                }
                Button {
                    text: (root.addonManagerOpen ? "Hide" : "Manage") + " (" + addonModel.count + " + " + resolverModel.count + ")"
                    enabled: !root.addonBusy
                    onClicked: {
                        root.addonManagerOpen = !root.addonManagerOpen;
                        if (root.addonManagerOpen) root.loadAddons();
                        else { root.homeProvider = ""; root.loadHome(true); }
                    }
                }
            }

            RowLayout {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: tmdbTokenField
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholderText: root.tmdbConfigured
                                   ? "TMDB Read Access Token saved securely"
                                   : "Paste TMDB API Read Access Token"
                    enabled: !root.tmdbBusy
                    onAccepted: root.saveTmdbToken()
                    Keys.onEscapePressed: function(event) {
                        tmdbTokenField.clear();
                        event.accepted = true;
                    }
                }
                Button {
                    text: root.tmdbBusy ? "Checking…" : root.tmdbConfigured ? "Replace TMDB token" : "Connect TMDB"
                    selected: root.tmdbConfigured
                    enabled: !root.tmdbBusy && tmdbTokenField.text.trim().length > 0
                    onClicked: root.saveTmdbToken()
                }
                Button {
                    text: "Disconnect"
                    visible: root.tmdbConfigured
                    enabled: !root.tmdbBusy
                    onClicked: root.clearTmdbToken()
                }
            }

            // MDbList is optional: it only adds Rotten Tomatoes and Metacritic, and it
            // is the one source here that requires a key, so the app works without it.
            RowLayout {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: mdbKeyField
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholderText: root.mdbConfigured
                                   ? "MDbList API key saved securely"
                                   : "Paste MDbList API key (optional — adds Rotten Tomatoes, Metacritic, Trakt, Letterboxd)"
                    enabled: !root.mdbBusy
                    onAccepted: root.saveMdbKey()
                    Keys.onEscapePressed: function(event) {
                        mdbKeyField.clear();
                        event.accepted = true;
                    }
                }
                Button {
                    text: root.mdbBusy ? "Checking…" : root.mdbConfigured ? "Replace MDbList key" : "Connect MDbList"
                    selected: root.mdbConfigured
                    enabled: !root.mdbBusy && mdbKeyField.text.trim().length > 0
                    onClicked: root.saveMdbKey()
                }
                Button {
                    text: "Disconnect"
                    visible: root.mdbConfigured
                    enabled: !root.mdbBusy
                    onClicked: root.clearMdbKey()
                }
            }

            Text {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.mdbMessage || (root.mdbConfigured
                      ? "MDbList connected • credential stored in ~/.config/omamovie/mdblist.json"
                      : "Optional: adds Rotten Tomatoes, Metacritic, Trakt and Letterboxd scores. Free key at mdblist.com.")
                wrapMode: Text.WordWrap
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.caption - 1)
                color: Qt.darker(Color.foreground, 1.4)
            }

            Text {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.tmdbMessage || (root.tmdbConfigured
                      ? "TMDB metadata connected • credential stored in ~/.config/omamovie/tmdb.json"
                      : "Optional: enables cast, crew and episode plots. Only the Read Access Token is required.")
                elide: Text.ElideRight
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.caption - 1)
                color: root.tmdbConfigured ? Color.accent : Qt.darker(Color.foreground, 1.35)
            }

            Text {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: "This product uses the TMDB API but is not endorsed or certified by TMDB."
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.caption - 2)
                color: Qt.darker(Color.foreground, 1.5)
            }

            RowLayout {
                visible: root.settingsSection === "addons"
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: resolverManifestField
                    Layout.fillWidth: true
                    placeholderText: "Paste authorized https://…/resolver.json"
                    enabled: !root.addonBusy
                    onAccepted: root.addResolver()
                    Keys.onEscapePressed: function(event) {
                        resolverManifestField.clear();
                        event.accepted = true;
                    }
                }
                Button {
                    text: root.addonBusy ? "Checking …" : "Add resolver"
                    selected: true
                    enabled: !root.addonBusy && resolverManifestField.text.trim().length > 0
                    onClicked: root.addResolver()
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.settingsSection === "addons" && (root.addonMessage.length > 0)
                textFormat: Text.PlainText
                text: root.addonMessage
                elide: Text.ElideRight
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.caption - 1)
                color: root.addonMessage.indexOf("bad request:") >= 0 || root.addonMessage.indexOf("Could not") >= 0
                       ? Color.urgent : Color.accent
            }

            ListView {
                flickDeceleration: 900
                maximumFlickVelocity: 6000
                ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }
                id: addonList
                Layout.fillWidth: true
                Layout.preferredHeight: root.addonManagerOpen ? Math.min(addonModel.count * 36, 108) : 0
                visible: root.settingsSection === "addons" && (root.addonManagerOpen && addonModel.count > 0)
                clip: true
                spacing: 4
                model: addonModel
                boundsBehavior: Flickable.StopAtBounds
                delegate: RowLayout {
                    width: addonList.width
                    height: 32
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: (model.addonAvailable ? "● " : model.addonEnabled ? "○ " : "– ")
                              + model.addonName
                              + (model.addonHost ? "  •  " + model.addonHost : "")
                              + (model.addonResources ? "  •  " + model.addonResources : "")
                        elide: Text.ElideRight
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: model.addonEnabled ? Color.foreground : Qt.darker(Color.foreground, 1.5)
                    }
                    Button {
                        text: model.addonEnabled ? "On" : "Off"
                        selected: model.addonEnabled
                        enabled: !root.addonBusy
                        fontSize: root.fs(Style.font.caption)
                        onClicked: root.toggleAddon(model.manifestUrl, !model.addonEnabled)
                    }
                    Button {
                        text: "Remove"
                        tooltipText: "Remove this manifest from OmaCine"
                        enabled: !root.addonBusy
                        fontSize: root.fs(Style.font.caption)
                        onClicked: root.removeAddon(model.manifestUrl, model.addonName)
                    }
                }
            }


            ListView {
                flickDeceleration: 900
                maximumFlickVelocity: 6000
                ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }
                id: resolverList
                Layout.fillWidth: true
                Layout.preferredHeight: root.addonManagerOpen ? Math.min(resolverModel.count * 36, 108) : 0
                visible: root.settingsSection === "addons" && (root.addonManagerOpen && resolverModel.count > 0)
                clip: true
                spacing: 4
                model: resolverModel
                boundsBehavior: Flickable.StopAtBounds
                delegate: RowLayout {
                    width: resolverList.width
                    height: 32
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: "Resolver  "
                              + (model.resolverAvailable ? "● " : model.resolverEnabled ? "○ " : "– ")
                              + model.resolverName
                              + (model.resolverHost ? "  •  " + model.resolverHost : "")
                              + "  •  " + model.resolverMappings + " mapping" + (model.resolverMappings === 1 ? "" : "s")
                        elide: Text.ElideRight
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: model.resolverEnabled ? Color.foreground : Qt.darker(Color.foreground, 1.5)
                    }
                    Button {
                        text: model.resolverBuiltin ? "Built-in" : (model.resolverEnabled ? "On" : "Off")
                        selected: model.resolverEnabled
                        enabled: !root.addonBusy && !model.resolverBuiltin
                        fontSize: root.fs(Style.font.caption)
                        onClicked: root.toggleResolver(model.resolverUrl, !model.resolverEnabled)
                    }
                    Button {
                        text: "Remove"
                        visible: !model.resolverBuiltin
                        tooltipText: "Remove this resolver manifest from OmaCine"
                        enabled: !root.addonBusy
                        fontSize: root.fs(Style.font.caption)
                        onClicked: root.removeResolver(model.resolverUrl, model.resolverName)
                    }
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            visible: root.provider === "stremio" && root.view === "discover" && !root.addonManagerOpen
            spacing: 6
            Button { text: "All"; fontSize: root.fs(Style.font.caption); selected: root.discoveryType === "all"; enabled: !root.homeLoading; onClicked: root.setDiscoveryFilter("type", "all") }
            Button { text: "Movies"; fontSize: root.fs(Style.font.caption); selected: root.discoveryType === "movie"; enabled: !root.homeLoading; onClicked: root.setDiscoveryFilter("type", "movie") }
            Button { text: "TV Shows"; fontSize: root.fs(Style.font.caption); selected: root.discoveryType === "series"; enabled: !root.homeLoading; onClicked: root.setDiscoveryFilter("type", "series") }
            Rectangle { width: 1; height: 26; color: Color.foreground; opacity: 0.15 }
            Button { text: "Popular"; fontSize: root.fs(Style.font.caption); selected: root.discoverySort === "popular"; enabled: !root.homeLoading; onClicked: root.setDiscoveryFilter("sort", "popular") }
            Button { text: "New"; fontSize: root.fs(Style.font.caption); selected: root.discoverySort === "new"; enabled: !root.homeLoading; onClicked: root.setDiscoveryFilter("sort", "new") }
            Button { text: "Top Rated"; fontSize: root.fs(Style.font.caption); selected: root.discoverySort === "rating"; enabled: !root.homeLoading; onClicked: root.setDiscoveryFilter("sort", "rating") }
            Dropdown {
                width: 150
                showLabel: false
                value: root.discoveryCatalogKey
                options: root.catalogOptions()
                enabled: !root.homeLoading
                onChanged: function(nextValue) { root.setDiscoveryFilter("catalog", nextValue) }
            }
            Dropdown {
                width: 130
                showLabel: false
                value: root.discoveryGenre
                options: [
                    { value: "", label: "All genres" }, { value: "action", label: "Action" },
                    { value: "comedy", label: "Comedy" }, { value: "drama", label: "Drama" },
                    { value: "thriller", label: "Thriller" }, { value: "animation", label: "Animation" },
                    { value: "documentary", label: "Documentary" }, { value: "horror", label: "Horror" },
                    { value: "sci-fi", label: "Sci-Fi" }, { value: "romance", label: "Romance" }
                ]
                enabled: !root.homeLoading
                onChanged: function(nextValue) { root.setDiscoveryFilter("genre", nextValue) }
            }
            Dropdown {
                width: 110
                showLabel: false
                value: root.discoveryYear
                options: [
                    { value: "", label: "Any year" }, { value: "2026", label: "2026" },
                    { value: "2025", label: "2025" }, { value: "2024", label: "2024" },
                    { value: "2023", label: "2023" }, { value: "2020s", label: "2020s" },
                    { value: "2010s", label: "2010s" }
                ]
                enabled: !root.homeLoading
                onChanged: function(nextValue) { root.setDiscoveryFilter("year", nextValue) }
            }
        }

        // body — fills the fixed panel; same size on every view
        Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.addonManagerOpen
            Layout.minimumHeight: Math.round(Math.min(Math.max(300, panel.screenH * 0.52), panel.screenH * 0.60))
            clip: true

            // ---- OmaCine cinematic home ----
            Item {
                anchors.fill: parent
                visible: root.view === "home"

                Flickable {
                    ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }
                    id: cinematicHome
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: cinematicHomeColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick
                    flickDeceleration: 900
                    maximumFlickVelocity: 6000

                    // Qt's Wayland touchpad path supplies smooth pixel deltas
                    // here, but does not start a Flickable flick on release.
                    // Preserve native one-for-one tracking, then continue with
                    // the velocity measured from the final gesture updates.
                    property real touchpadVelocityY: 0
                    property double touchpadLastMs: 0
                    property bool touchpadTracking: false
                    property real pendingTouchpadVelocityY: 0

                    Timer {
                        id: touchpadFlickLaunch
                        interval: 0
                        repeat: false
                        onTriggered: {
                            const velocity = cinematicHome.pendingTouchpadVelocityY
                            const maximumY = Math.max(0, cinematicHome.contentHeight - cinematicHome.height)
                            const canContinue = (velocity < 0 && cinematicHome.contentY < maximumY)
                                                || (velocity > 0 && cinematicHome.contentY > 0)
                            cinematicHome.pendingTouchpadVelocityY = 0
                            if (canContinue)
                                cinematicHome.flick(0, velocity)
                        }
                    }

                    WheelHandler {
                        target: null
                        blocking: false
                        orientation: Qt.Vertical
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: function(event) {
                            const now = Date.now()
                            const pixelY = event.pixelDelta.y

                            if (pixelY !== 0) {
                                const elapsed = now - cinematicHome.touchpadLastMs
                                const instantaneousVelocity = elapsed > 0
                                        ? pixelY * 1000 / elapsed : 0
                                const stale = !cinematicHome.touchpadTracking || elapsed > 80
                                const reversed = cinematicHome.touchpadVelocityY !== 0
                                        && instantaneousVelocity * cinematicHome.touchpadVelocityY < 0

                                if (instantaneousVelocity !== 0) {
                                    if (stale || reversed)
                                        cinematicHome.touchpadVelocityY = instantaneousVelocity
                                    else
                                        cinematicHome.touchpadVelocityY = cinematicHome.touchpadVelocityY * 0.65
                                                + instantaneousVelocity * 0.35
                                }
                                cinematicHome.touchpadLastMs = now
                                cinematicHome.touchpadTracking = true
                            }

                            if (event.phase === Qt.ScrollEnd && cinematicHome.touchpadTracking) {
                                const releaseAge = now - cinematicHome.touchpadLastMs
                                let velocity = releaseAge <= 100
                                        ? cinematicHome.touchpadVelocityY * 1.25 : 0
                                velocity = Math.max(-cinematicHome.maximumFlickVelocity,
                                                    Math.min(cinematicHome.maximumFlickVelocity, velocity))
                                cinematicHome.pendingTouchpadVelocityY = Math.abs(velocity) >= 180
                                        ? velocity : 0
                                cinematicHome.touchpadVelocityY = 0
                                cinematicHome.touchpadLastMs = 0
                                cinematicHome.touchpadTracking = false
                                if (cinematicHome.pendingTouchpadVelocityY !== 0)
                                    touchpadFlickLaunch.restart()
                            }
                        }
                    }

                    ColumnLayout {
                        id: cinematicHomeColumn
                        width: cinematicHome.width
                        spacing: Math.round(14 * panel.uiScale)

                        OmaCineHero {
                            id: cinematicHero
                            Layout.fillWidth: true
                            // Track the viewport instead of a fixed 260 px, so a
                            // bigger window actually shows a bigger frame.
                            Layout.preferredHeight: Math.round(Math.max(260, Math.min(620, cinematicHome.height * 0.60)))
                            item: root.heroItem
                            loading: root.cinematicHomeLoading
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            slideCount: root.heroItems.length
                            slideIndex: root.heroIndex
                            overlayOpacity: Number(root.settings.heroOverlay)
                            onActivated: if (root.heroItem) root.openItem(root.heroItem)
                            onLibraryRequested: root.openLibrary()
                            onSlideRequested: function(index) { root.showHeroSlide(index); }
                            onHoveredChanged: root.heroHovered = hovered
                        }

                        OmaCineMediaRail {
                            Layout.fillWidth: true
                            visible: continueModel.count > 0
                            title: "Continue Watching"
                            subtitle: "Pick up exactly where you stopped"
                            mediaModel: continueModel
                            showProgress: true
                            removable: true
                            onRemoveRequested: function(item) { root.removeWatchEntry(item); }
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            onActivated: function(item) { root.openItem(item); }
                            onPreviewRequested: function(item) { if (root.settings.railHoverPreview !== true) return; root.prefetchDetails(item.id, item.provider); root.prefetchStreams(item); }
                        }

                        OmaCineMediaRail {
                            Layout.fillWidth: true
                            visible: cinematicTrendingModel.count > 0
                            title: "Trending This Week"
                            subtitle: "What people are watching now"
                            mediaModel: cinematicTrendingModel
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            onActivated: function(item) { root.openItem(item); }
                            onPreviewRequested: function(item) { if (root.settings.railHoverPreview !== true) return; root.prefetchDetails(item.id, item.provider); root.prefetchStreams(item); }
                        }

                        OmaCineMediaRail {
                            Layout.fillWidth: true
                            visible: cinematicNewModel.count > 0
                            title: "Now Playing"
                            subtitle: "Recent movie releases"
                            mediaModel: cinematicNewModel
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            onActivated: function(item) { root.openItem(item); }
                            onPreviewRequested: function(item) { if (root.settings.railHoverPreview !== true) return; root.prefetchDetails(item.id, item.provider); root.prefetchStreams(item); }
                        }

                        OmaCineMediaRail {
                            Layout.fillWidth: true
                            visible: cinematicTvModel.count > 0
                            title: "Popular TV"
                            subtitle: "Series worth settling into"
                            mediaModel: cinematicTvModel
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            onActivated: function(item) { root.openItem(item); }
                            onPreviewRequested: function(item) { if (root.settings.railHoverPreview !== true) return; root.prefetchDetails(item.id, item.provider); root.prefetchStreams(item); }
                        }

                        OmaCineMediaRail {
                            Layout.fillWidth: true
                            visible: cinematicMovieModel.count > 0
                            title: "Popular Movies"
                            subtitle: "Audience favourites"
                            mediaModel: cinematicMovieModel
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            onActivated: function(item) { root.openItem(item); }
                            onPreviewRequested: function(item) { if (root.settings.railHoverPreview !== true) return; root.prefetchDetails(item.id, item.provider); root.prefetchStreams(item); }
                        }

                        OmaCineMediaRail {
                            Layout.fillWidth: true
                            visible: cinematicAiringModel.count > 0
                            title: "On Air"
                            subtitle: "Television with new episodes"
                            mediaModel: cinematicAiringModel
                            uiScale: panel.uiScale
                            textScale: root.textScale
                            uiFont: root.uiFont
                            urlResolver: root.imageSource
                            onActivated: function(item) { root.openItem(item); }
                            onPreviewRequested: function(item) { if (root.settings.railHoverPreview !== true) return; root.prefetchDetails(item.id, item.provider); root.prefetchStreams(item); }
                        }

                        Button {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Explore the full catalog"
                            iconText: "\uf002"
                            selected: true
                            onClicked: root.openDiscover(false)
                        }
                        Item { Layout.preferredHeight: 6 }
                    }
                }
            }

            // ---- discover catalog ----
            Item {
                anchors.fill: parent
                visible: root.view === "discover"
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        visible: false
                        text: "Continue Watching"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.body)
                        font.bold: true
                        color: Color.accent
                    }
                    ListView {
                        flickDeceleration: 900
                        maximumFlickVelocity: 6000
                        id: continueList
                        Layout.fillWidth: true
                        Layout.preferredHeight: visible ? Math.round(112 * panel.uiScale) : 0
                        visible: false
                        orientation: ListView.Horizontal
                        spacing: 8
                        clip: true
                        model: continueModel
                        boundsBehavior: Flickable.StopAtBounds
                        delegate: Rectangle {
                            width: Math.round(250 * panel.uiScale)
                            height: continueList.height
                            radius: Style.cornerRadius
                            color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                            border.width: continueMouse.containsMouse ? 1 : 0
                            border.color: Color.accent
                            Row {
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 8
                                Rectangle {
                                    width: 68 * panel.uiScale
                                    height: parent.height
                                    radius: Style.cornerRadius
                                    color: Qt.darker(Color.foreground, 2.2)
                                    clip: true
                                    Image { anchors.fill: parent; source: root.imageSource(model.coverPath) || root.imageSource(model.cover); fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: true; sourceSize.width: Math.round(width); sourceSize.height: Math.round(height) }
                                }
                                Column {
                                    width: parent.width - (76 * panel.uiScale)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 5
                                    Text { width: parent.width; text: model.title; elide: Text.ElideRight; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption); font.bold: true; color: Color.foreground }
                                    Text {
                                        width: parent.width
                                        text: model.stype === 2 && model.resumeEpisode > 0 ? root.episodeCode(model.resumeSeason, model.resumeEpisode) : "Movie"
                                        font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 2); color: Qt.darker(Color.foreground, 1.35)
                                    }
                                    Text { width: parent.width; text: "Resume • " + root.fmtDur(model.position); font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 2); color: Color.accent }
                                    Rectangle {
                                        width: parent.width; height: 4; radius: 2; color: Qt.darker(Color.foreground, 1.9)
                                        Rectangle { width: parent.width * Math.max(0, Math.min(1, model.progress)); height: parent.height; radius: 2; color: Color.accent }
                                    }
                                }
                            }
                            MouseArea { id: continueMouse; anchors.fill: parent; hoverEnabled: true; scrollGestureEnabled: false; cursorShape: Qt.PointingHandCursor; onClicked: root.openItem(continueModel.get(index)) }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            text: root.homeLoading ? "Loading catalogs…" : (root.provider === "stremio" ? (root.discoverySort === "new" ? "New releases" : root.discoverySort === "rating" ? "Top rated" : "Popular now") : (homeModel.count ? "Discover • tap any title" : "Discover"))
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.body)
                            font.bold: true
                            color: Color.accent
                        }
                    }
                    GridView {
                        ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }
                        id: homeGrid
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        cacheBuffer: 400
                        flickableDirection: Flickable.VerticalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 900
                        maximumFlickVelocity: 6000

                        // Qt's Wayland touchpad path supplies smooth pixel deltas
                        // here, but does not start a Flickable flick on release.
                        // Preserve native one-for-one tracking, then continue with
                        // the velocity measured from the final gesture updates.
                        property real touchpadVelocityY: 0
                        property double touchpadLastMs: 0
                        property bool touchpadTracking: false
                        property real pendingTouchpadVelocityY: 0

                        Timer {
                            id: discoverTouchpadFlickLaunch
                            interval: 0
                            repeat: false
                            onTriggered: {
                                const velocity = homeGrid.pendingTouchpadVelocityY
                                const maximumY = Math.max(0, homeGrid.contentHeight - homeGrid.height)
                                const canContinue = (velocity < 0 && homeGrid.contentY < maximumY)
                                                    || (velocity > 0 && homeGrid.contentY > 0)
                                homeGrid.pendingTouchpadVelocityY = 0
                                if (canContinue)
                                    homeGrid.flick(0, velocity)
                            }
                        }

                        WheelHandler {
                            target: null
                            blocking: false
                            orientation: Qt.Vertical
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: function(event) {
                                const now = Date.now()
                                const pixelY = event.pixelDelta.y

                                if (pixelY !== 0) {
                                    const elapsed = now - homeGrid.touchpadLastMs
                                    const instantaneousVelocity = elapsed > 0
                                            ? pixelY * 1000 / elapsed : 0
                                    const stale = !homeGrid.touchpadTracking || elapsed > 80
                                    const reversed = homeGrid.touchpadVelocityY !== 0
                                            && instantaneousVelocity * homeGrid.touchpadVelocityY < 0

                                    if (instantaneousVelocity !== 0) {
                                        if (stale || reversed)
                                            homeGrid.touchpadVelocityY = instantaneousVelocity
                                        else
                                            homeGrid.touchpadVelocityY = homeGrid.touchpadVelocityY * 0.65
                                                    + instantaneousVelocity * 0.35
                                    }
                                    homeGrid.touchpadLastMs = now
                                    homeGrid.touchpadTracking = true
                                }

                                if (event.phase === Qt.ScrollEnd && homeGrid.touchpadTracking) {
                                    const releaseAge = now - homeGrid.touchpadLastMs
                                    let velocity = releaseAge <= 100
                                            ? homeGrid.touchpadVelocityY * 1.25 : 0
                                    velocity = Math.max(-homeGrid.maximumFlickVelocity,
                                                        Math.min(homeGrid.maximumFlickVelocity, velocity))
                                    homeGrid.pendingTouchpadVelocityY = Math.abs(velocity) >= 180
                                            ? velocity : 0
                                    homeGrid.touchpadVelocityY = 0
                                    homeGrid.touchpadLastMs = 0
                                    homeGrid.touchpadTracking = false
                                    if (homeGrid.pendingTouchpadVelocityY !== 0)
                                        discoverTouchpadFlickLaunch.restart()
                                }
                            }
                        }

                        reuseItems: true
                        visible: !root.homeLoading
                        model: homeModel
                        cellWidth: Math.round(168 * panel.uiScale)
                        cellHeight: Math.round(236 * panel.uiScale)
                        delegate: Item {
                            id: homeDelegate
                            width: homeGrid.cellWidth
                            height: homeGrid.cellHeight
                            property bool hovered: homeMouse.containsMouse
                            Column {
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 5
                                Rectangle {
                                    width: parent.width
                                    height: parent.height * 0.74
                                    radius: Style.cornerRadius
                                    color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                                    border.width: homeDelegate.hovered ? 1 : 0
                                    border.color: homeDelegate.hovered ? Color.accent : "transparent"
                                    clip: true
                                    // hover scale removed
                                    Image {
                                        anchors.fill: parent
                                        source: root.imageSource(model.coverPath) || root.imageSource(model.cover)
                                        // Decode at draw size; full-resolution posters are what stall scrolling.
                                        sourceSize.width: Math.round(width)
                                        sourceSize.height: Math.round(height)
                                        fillMode: Image.PreserveAspectCrop
                                        visible: source !== ""
                                        asynchronous: true
                                        cache: true
                                    }
                                    Rectangle {
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                        height: 22; color: "#66000000"; visible: model.rating && model.rating !== "-"
                                        Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "\u2605 " + model.rating; font.family: root.uiFont; font.pixelSize: root.fs(10); color: "white"; font.bold: true}
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: !model.cover && !model.coverPath
                                        text: ""
                                        font.family: root.uiFont
                                        font.pixelSize: root.fs(30)
                                        color: Qt.darker(Color.foreground, 1.3)
                                    }
                                }
                                Text {
                                    width: parent.width
                                    textFormat: Text.PlainText
                                    text: model.title
                                    elide: Text.ElideRight
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption)
                                    color: Color.foreground
                                    maximumLineCount: 1
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    text: (model.year ? model.year : "\u2013") + "  \u2605 " + model.rating
                                    elide: Text.ElideRight
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption - 2)
                                    color: Qt.darker(Color.foreground, 1.5)
                                }
                            }
                            MouseArea {
                                id: homeMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                hoverEnabled: true
                                // Card clicks only: without this the delegate
                                // swallows touchpad scroll meant for homeGrid.
                                scrollGestureEnabled: false
                                enabled: !root.busy && !root.homeLoading
                                onEntered: homeHoverTimer.restart()
                                onExited: homeHoverTimer.stop()
                                onClicked: { if (!root.busy && !root.homeLoading) root.openHomeDetails(index) }
                                Timer {
                                    id: homeHoverTimer
                                    interval: 380
                                    repeat: false
                                    onTriggered: root.prefetchDetails(model.id, model.provider)
                                }
                            }
                        }
                    }
                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        visible: root.provider === "stremio" && !root.homeLoading && root.discoveryHasMore
                        text: root.homeAppending ? "Loading more…" : "Load more"
                        enabled: !root.homeAppending
                        selected: true
                        onClicked: root.loadMoreTv()
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.homeLoading
                        text: "Loading highlights \u2026"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.body)
                        color: Qt.darker(Color.foreground, 1.5)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !root.homeLoading && homeModel.count === 0
                        text: root.provider === "stremio" ? "No catalog titles found — adjust filters or check Sources." : "No highlights yet — try Search above."
                        horizontalAlignment: Text.AlignHCenter
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Qt.darker(Color.foreground, 1.4)
                    }
                }
            }

            // ---- My Library ----
            Item {
                anchors.fill: parent
                visible: root.view === "library"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: "My Library"
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.title)
                            font.bold: true
                            color: Color.foreground
                        }
                        Text {
                            text: root.libraryEntries.length + (root.libraryEntries.length === 1 ? " saved title" : " saved titles")
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption)
                            color: Qt.darker(Color.foreground, 1.4)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            text: "Movies (" + root.libraryCount(1) + ")"
                            selected: root.libraryTab === "movie"
                            enabled: !root.libraryBusy
                            onClicked: root.setLibraryTab("movie")
                        }
                        Button {
                            text: "TV Shows (" + root.libraryCount(2) + ")"
                            selected: root.libraryTab === "series"
                            enabled: !root.libraryBusy
                            onClicked: root.setLibraryTab("series")
                        }
                        Item { Layout.fillWidth: true }
                        TextField {
                            id: librarySearchField
                            Layout.preferredWidth: Math.round(250 * panel.uiScale)
                            placeholderText: root.libraryTab === "series" ? "Search saved TV shows…" : "Search saved movies…"
                            onTextChanged: {
                                root.libraryQuery = text;
                                root.rebuildLibraryView();
                            }
                            Keys.onEscapePressed: function(event) {
                                clear();
                                event.accepted = true;
                            }
                        }
                        Dropdown {
                            width: 160
                            showLabel: false
                            value: root.librarySort
                            options: [
                                { value: "recent", label: "Recently added" },
                                { value: "title", label: "Title A–Z" },
                                { value: "year", label: "Newest year" },
                                { value: "rating", label: "Highest rated" }
                            ]
                            onChanged: function(nextValue) {
                                root.librarySort = nextValue;
                                root.rebuildLibraryView();
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: libraryDisplayModel.count + (libraryDisplayModel.count === 1 ? " title" : " titles")
                              + (root.libraryQuery ? (" matching “" + root.libraryQuery + "”") : "")
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption)
                        color: Color.accent
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        GridView {
                            ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }
                            id: libraryGrid
                            anchors.fill: parent
                            visible: libraryDisplayModel.count > 0
                            model: libraryDisplayModel
                            clip: true
                            cacheBuffer: 500
                            flickableDirection: Flickable.VerticalFlick
                            boundsBehavior: Flickable.StopAtBounds
                            flickDeceleration: 900
                            maximumFlickVelocity: 6000

                            // Qt's Wayland touchpad path supplies smooth pixel deltas here, but
                            // does not start a Flickable flick on release. Preserve native
                            // one-for-one tracking, then continue with the velocity measured
                            // from the final gesture updates.
                            property real touchpadVelocityY: 0
                            property double touchpadLastMs: 0
                            property bool touchpadTracking: false
                            property real pendingTouchpadVelocityY: 0

                            Timer {
                                id: libraryTouchpadFlickLaunch
                                interval: 0
                                repeat: false
                                onTriggered: {
                                    const velocity = libraryGrid.pendingTouchpadVelocityY
                                    const maximumPos = Math.max(0, libraryGrid.contentHeight - libraryGrid.height)
                                    const canContinue = (velocity < 0 && libraryGrid.contentY < maximumPos)
                                                                || (velocity > 0 && libraryGrid.contentY > 0)
                                    libraryGrid.pendingTouchpadVelocityY = 0
                                    if (canContinue)
                                        libraryGrid.flick(0, velocity)
                                }
                            }

                            WheelHandler {
                                target: null
                                blocking: false
                                orientation: Qt.Vertical
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onWheel: function(event) {
                                    const now = Date.now()
                                    const delta = event.pixelDelta.y

                                    if (delta !== 0) {
                                        const elapsed = now - libraryGrid.touchpadLastMs
                                        const instantaneousVelocity = elapsed > 0 ? delta * 1000 / elapsed : 0
                                        const stale = !libraryGrid.touchpadTracking || elapsed > 80
                                        const reversed = libraryGrid.touchpadVelocityY !== 0
                                                && instantaneousVelocity * libraryGrid.touchpadVelocityY < 0

                                        if (instantaneousVelocity !== 0) {
                                            if (stale || reversed)
                                                libraryGrid.touchpadVelocityY = instantaneousVelocity
                                            else
                                                libraryGrid.touchpadVelocityY = libraryGrid.touchpadVelocityY * 0.65 + instantaneousVelocity * 0.35
                                        }
                                        libraryGrid.touchpadLastMs = now
                                        libraryGrid.touchpadTracking = true
                                    }

                                    if (event.phase === Qt.ScrollEnd && libraryGrid.touchpadTracking) {
                                        const releaseAge = now - libraryGrid.touchpadLastMs
                                        let velocity = releaseAge <= 100 ? libraryGrid.touchpadVelocityY * 1.25 : 0
                                        velocity = Math.max(-libraryGrid.maximumFlickVelocity,
                                                            Math.min(libraryGrid.maximumFlickVelocity, velocity))
                                        libraryGrid.pendingTouchpadVelocityY = Math.abs(velocity) >= 180 ? velocity : 0
                                        libraryGrid.touchpadVelocityY = 0
                                        libraryGrid.touchpadLastMs = 0
                                        libraryGrid.touchpadTracking = false
                                        if (libraryGrid.pendingTouchpadVelocityY !== 0)
                                            libraryTouchpadFlickLaunch.restart()
                                    }
                                }
                            }
                            reuseItems: true
                            cellWidth: Math.round(168 * panel.uiScale)
                            cellHeight: Math.round(236 * panel.uiScale)
                            delegate: libraryCardDelegate
                        }
                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 30
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            visible: libraryDisplayModel.count === 0
                            text: root.libraryQuery
                                ? "No saved titles match this search"
                                : root.libraryTab === "series"
                                  ? "TV shows you save will appear here"
                                  : "Movies you save will appear here"
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption)
                            color: Qt.darker(Color.foreground, 1.4)
                        }
                    }
                }
            }

            // ---- results grid ----
            GridView {
                ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }
                id: grid
                anchors.fill: parent
                visible: root.view === "grid"
                model: resultModel
                clip: true
                cacheBuffer: 600
                flickableDirection: Flickable.VerticalFlick
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 900
                maximumFlickVelocity: 6000

                // Qt's Wayland touchpad path supplies smooth pixel deltas here, but
                // does not start a Flickable flick on release. Preserve native
                // one-for-one tracking, then continue with the velocity measured
                // from the final gesture updates.
                property real touchpadVelocityY: 0
                property double touchpadLastMs: 0
                property bool touchpadTracking: false
                property real pendingTouchpadVelocityY: 0

                Timer {
                    id: resultsTouchpadFlickLaunch
                    interval: 0
                    repeat: false
                    onTriggered: {
                        const velocity = grid.pendingTouchpadVelocityY
                        const maximumPos = Math.max(0, grid.contentHeight - grid.height)
                        const canContinue = (velocity < 0 && grid.contentY < maximumPos)
                                                    || (velocity > 0 && grid.contentY > 0)
                        grid.pendingTouchpadVelocityY = 0
                        if (canContinue)
                            grid.flick(0, velocity)
                    }
                }

                WheelHandler {
                    target: null
                    blocking: false
                    orientation: Qt.Vertical
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: function(event) {
                        const now = Date.now()
                        const delta = event.pixelDelta.y

                        if (delta !== 0) {
                            const elapsed = now - grid.touchpadLastMs
                            const instantaneousVelocity = elapsed > 0 ? delta * 1000 / elapsed : 0
                            const stale = !grid.touchpadTracking || elapsed > 80
                            const reversed = grid.touchpadVelocityY !== 0
                                    && instantaneousVelocity * grid.touchpadVelocityY < 0

                            if (instantaneousVelocity !== 0) {
                                if (stale || reversed)
                                    grid.touchpadVelocityY = instantaneousVelocity
                                else
                                    grid.touchpadVelocityY = grid.touchpadVelocityY * 0.65 + instantaneousVelocity * 0.35
                            }
                            grid.touchpadLastMs = now
                            grid.touchpadTracking = true
                        }

                        if (event.phase === Qt.ScrollEnd && grid.touchpadTracking) {
                            const releaseAge = now - grid.touchpadLastMs
                            let velocity = releaseAge <= 100 ? grid.touchpadVelocityY * 1.25 : 0
                            velocity = Math.max(-grid.maximumFlickVelocity,
                                                Math.min(grid.maximumFlickVelocity, velocity))
                            grid.pendingTouchpadVelocityY = Math.abs(velocity) >= 180 ? velocity : 0
                            grid.touchpadVelocityY = 0
                            grid.touchpadLastMs = 0
                            grid.touchpadTracking = false
                            if (grid.pendingTouchpadVelocityY !== 0)
                                resultsTouchpadFlickLaunch.restart()
                        }
                    }
                }
                reuseItems: true
                cellWidth: Math.round(168 * panel.uiScale)
                cellHeight: Math.round(236 * panel.uiScale)
                delegate: Item {
                    id: gridDelegate
                    width: grid.cellWidth
                    height: grid.cellHeight
                    property bool hovered: gridMouse.containsMouse
                    Column {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 5
                        Rectangle {
                            width: parent.width
                            height: parent.height * 0.74
                            radius: Style.cornerRadius
                            color: Color.surface ?? Qt.darker(Color.foreground, 2.15)
                            border.width: gridDelegate.hovered ? 1 : 0
                            border.color: gridDelegate.hovered ? Color.accent : "transparent"
                            clip: true
                            // hover scale removed for scroll performance
                            Behavior on border.width { NumberAnimation { duration: 100 } }
                            Image {
                                anchors.fill: parent
                                source: root.imageSource(model.coverPath) || root.imageSource(model.cover)
                                // Decode at draw size; full-resolution posters are what stall scrolling.
                                sourceSize.width: Math.round(width)
                                sourceSize.height: Math.round(height)
                                fillMode: Image.PreserveAspectCrop
                                visible: source !== ""
                                asynchronous: true
                                cache: true
                            }
                            // subtle gradient + rating badge
                            Rectangle {
                                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                height: 22; radius: 0
                                visible: model.rating && model.rating !== "-"
                                color: "#66000000"
                                Text {
                                    anchors.centerIn: parent
                                    textFormat: Text.PlainText
                                    text: "\u2605 " + model.rating
                                    font.family: root.uiFont; font.pixelSize: root.fs(10); color: "white"; font.bold: true
                                }
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !model.cover && !model.coverPath
                                text: ""
                                font.family: root.uiFont
                                font.pixelSize: root.fs(30)
                                color: Qt.darker(Color.foreground, 1.3)
                            }
                        }
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: model.title
                            elide: Text.ElideRight
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption)
                            color: Color.foreground
                            maximumLineCount: 1
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: (model.year ? model.year : "\u2013") + "  \u2605 " + model.rating
                            elide: Text.ElideRight
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption - 2)
                            color: Qt.darker(Color.foreground, 1.5)
                        }
                    }
                    MouseArea {
                        id: gridMouse
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        // Clicks only: a delegate that consumes scroll gestures
                        // starves the surrounding Flickable of the release event.
                        scrollGestureEnabled: false
                        enabled: !root.busy
                        onEntered: if (!root.busy) hoverTimer.restart()
                        onExited: hoverTimer.stop()
                        onClicked: { if (!root.busy) root.openDetails(index) }
                        Timer {
                            id: hoverTimer
                            interval: 380
                            repeat: false
                            onTriggered: root.prefetchDetails(model.id, model.provider)
                        }
                    }
                }
            }

            // ---- calendar ----
            // Month grid plus a forward-looking rail, after Stremio's layout:
            // posters in day cells read far faster than lists of titles.
            Item {
                anchors.fill: parent
                visible: root.view === "calendar"

                RowLayout {
                    anchors.fill: parent
                    spacing: 12

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Button {
                                text: "\u2039"
                                fontSize: root.fs(Style.font.subtitle)
                                enabled: !root.calendarLoading
                                onClicked: root.shiftCalendarMonth(-1)
                            }
                            Text {
                                text: root.calendarMonthLabel()
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.heading)
                                font.bold: true
                                color: Color.accent
                            }
                            Button {
                                text: "\u203A"
                                fontSize: root.fs(Style.font.subtitle)
                                enabled: !root.calendarLoading
                                onClicked: root.shiftCalendarMonth(1)
                            }
                            Button {
                                text: "Today"
                                fontSize: root.fs(Style.font.caption)
                                enabled: !root.calendarLoading
                                onClicked: {
                                    var now = new Date();
                                    root.calendarMonth = now.getFullYear() + "-"
                                        + ("0" + (now.getMonth() + 1)).slice(-2);
                                    root.calendarLoaded = false;
                                    root.loadCalendarMonth();
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Repeater {
                                model: [
                                    { c: root.calPremiere, t: "Premiere" },
                                    { c: root.calSeason,   t: "Season start" },
                                    { c: root.calFinale,   t: "Finale" }
                                ]
                                delegate: RowLayout {
                                    spacing: 4
                                    Rectangle {
                                        width: Math.round(9 * panel.uiScale); height: width; radius: 2
                                        color: modelData.c
                                    }
                                    Text {
                                        text: modelData.t
                                        font.family: root.uiFont
                                        font.pixelSize: root.fs(Style.font.caption - 3)
                                        color: Qt.darker(Color.foreground, 1.5)
                                    }
                                }
                            }
                        }

                        // weekday header
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Repeater {
                                model: ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
                                delegate: Text {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    text: modelData
                                    elide: Text.ElideRight
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption - 1)
                                    color: Qt.darker(Color.foreground, 1.5)
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 7
                            columnSpacing: 2
                            rowSpacing: 2

                            Repeater {
                                model: root.calendarCells
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.preferredWidth: 1
                                    color: modelData.filler
                                         ? "transparent"
                                         : Qt.rgba(Color.foreground.r, Color.foreground.g,
                                                   Color.foreground.b, 0.045)
                                    border.width: modelData.date === root.calendarToday ? 1 : 0
                                    border.color: Color.accent
                                    radius: 3
                                    clip: true

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 5
                                        spacing: 3
                                        visible: !modelData.filler

                                        Rectangle {
                                            Layout.preferredWidth: Math.round(20 * panel.uiScale)
                                            Layout.preferredHeight: Layout.preferredWidth
                                            radius: width / 2
                                            color: modelData.date === root.calendarToday
                                                 ? Color.accent : "transparent"
                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData.day !== undefined ? modelData.day : ""
                                                font.family: root.uiFont
                                                font.pixelSize: root.fs(Style.font.caption - 1)
                                                font.bold: modelData.date === root.calendarToday
                                                color: modelData.date === root.calendarToday
                                                     ? Color.popups.background : Qt.darker(Color.foreground, 1.3)
                                            }
                                        }

                                        Flow {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            spacing: 3
                                            Repeater {
                                                model: modelData.entries
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    width: Math.round(42 * panel.uiScale)
                                                    height: Math.round(63 * panel.uiScale)
                                                    radius: 3
                                                    color: "transparent"
                                                    border.width: root.calendarAccent(modelData) === "transparent" ? 0 : 2
                                                    border.color: root.calendarAccent(modelData)
                                                    clip: true
                                                    opacity: modelData.watched === true ? 0.42 : 1.0

                                                    Image {
                                                        anchors.fill: parent
                                                        anchors.margins: parent.border.width
                                                        source: root.imageSource(modelData.cover || "")
                                                        fillMode: Image.PreserveAspectCrop
                                                        asynchronous: true
                                                        sourceSize.width: 140
                                                    }
                                                    // The episode code sits on the art, as the
                                                    // poster alone cannot say which episode it is.
                                                    Rectangle {
                                                        anchors.left: parent.left
                                                        anchors.right: parent.right
                                                        anchors.bottom: parent.bottom
                                                        height: epCode.implicitHeight + 3
                                                        color: Qt.rgba(0, 0, 0, 0.66)
                                                        Text {
                                                            id: epCode
                                                            anchors.centerIn: parent
                                                            text: "S" + modelData.season + "E" + modelData.episode
                                                            font.family: root.dataFont
                                                            font.pixelSize: root.fs(Style.font.caption - 4)
                                                            color: "#FFFFFF"
                                                        }
                                                    }

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        ToolTip.visible: containsMouse
                                                        ToolTip.text: modelData.title + "  \u00B7  S"
                                                            + modelData.season + "E" + modelData.episode
                                                            + (modelData.episodeTitle ? "\n" + modelData.episodeTitle : "")
                                                        onClicked: root.openItem({
                                                            id: modelData.id, title: modelData.title,
                                                            cover: modelData.cover, provider: "stremio"
                                                        })
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---- what is next, regardless of the month on screen ----
                    Rectangle {
                        Layout.preferredWidth: Math.round(230 * panel.uiScale)
                        Layout.fillHeight: true
                        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
                        radius: Style.cornerRadius

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 6

                            Text {
                                text: "Up next"
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption)
                                font.bold: true
                                color: Color.accent
                            }

                            Flickable {
                                id: railFlick
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                contentHeight: railColumn.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                WheelHandler {
                                    target: null
                                    onWheel: function(event) {
                                        var step = event.pixelDelta.y !== 0 ? event.pixelDelta.y
                                                 : (event.angleDelta.y / 120) * 90;
                                        var maxY = Math.max(0, railFlick.contentHeight - railFlick.height);
                                        railFlick.contentY = Math.max(0, Math.min(maxY, railFlick.contentY - step));
                                    }
                                }

                                ColumnLayout {
                                    id: railColumn
                                    width: railFlick.width
                                    spacing: 8

                                    Repeater {
                                        model: root.calendarUpcoming
                                        delegate: ColumnLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: 2
                                            Text {
                                                text: root.prettyDate(modelData.date)
                                                font.family: root.uiFont
                                                font.pixelSize: root.fs(Style.font.caption - 1)
                                                font.weight: Font.DemiBold
                                                color: Color.foreground
                                            }
                                            Repeater {
                                                model: modelData.entries
                                                delegate: RowLayout {
                                                    required property var modelData
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: modelData.title
                                                        elide: Text.ElideRight
                                                        maximumLineCount: 1
                                                        font.family: root.uiFont
                                                        font.pixelSize: root.fs(Style.font.caption - 2)
                                                        color: Qt.darker(Color.foreground, 1.25)
                                                    }
                                                    Text {
                                                        text: "S" + modelData.season + "E" + modelData.episode
                                                        font.family: root.dataFont
                                                        font.pixelSize: root.fs(Style.font.caption - 3)
                                                        color: Qt.darker(Color.foreground, 1.6)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: root.calendarUpcoming.length === 0 && !root.calendarLoading
                                        text: "Nothing scheduled. Add shows to your library and their "
                                            + "episodes appear here."
                                        wrapMode: Text.WordWrap
                                        font.family: root.uiFont
                                        font.pixelSize: root.fs(Style.font.caption - 2)
                                        color: Qt.darker(Color.foreground, 1.6)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- details ----
            Item {
                anchors.fill: parent
                visible: root.view === "details"

                Image {
                    anchors.fill: parent
                    source: root.currentBackdrop
                    visible: source !== ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: Number(root.settings.backdropOpacity)
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                }
                VideoOutput {
                    id: themeVideoSurface
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                    opacity: root.themeVideoShown ? 1.0 : 0.0
                    visible: opacity > 0.01
                    // Long enough to read as a cross-fade rather than a cut.
                    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
                }
                Rectangle {
                    anchors.fill: parent
                    color: Color.popups.background
                    opacity: root.currentBackdrop ? Number(root.settings.backdropDim) : 0.0
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                }

                RowLayout {
                    anchors.fill: parent
                    spacing: 14

                    // poster
                    // left column: poster, trailer, ratings
                    ColumnLayout {
                        Layout.minimumWidth: Math.round(300 * panel.uiScale)
                        Layout.preferredWidth: Math.round(300 * panel.uiScale)
                        Layout.maximumWidth: Math.round(300 * panel.uiScale)
                        Layout.alignment: Qt.AlignTop
                        spacing: 8

                        Rectangle {
                            Layout.fillWidth: true
                            // Pinned to one height, the poster could not give any
                            // ground and everything below it was pushed off the
                            // page instead. A lower minimum lets the layout
                            // compress the poster under pressure, so the column
                            // stays correct at any text scale rather than only
                            // at the one it was tuned for.
                            Layout.minimumHeight: Math.round(300 * panel.uiScale)
                            Layout.preferredHeight: Math.round(450 * panel.uiScale)
                            Layout.maximumHeight: Math.round(450 * panel.uiScale)
                            Layout.fillHeight: false
                            Layout.alignment: Qt.AlignTop
                            radius: Style.cornerRadius
                            color: Qt.darker(Color.foreground, 2.2)
                            border.width: 1
                            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
                            clip: true
                            Image {
                                id: detailPoster
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                source: ""
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: detailPoster.source === ""
                                text: ""
                                font.family: root.uiFont
                                font.pixelSize: root.fs(40)
                                color: Qt.darker(Color.foreground, 1.3)
                            }
                        }

                        // ---- trailer card ----
                        Rectangle {
                            Layout.fillWidth: true
                            // 16:9 of a 300px column is 169px, which together with
                            // the poster and ratings pushed the theme control off
                            // the page. Capped: the thumbnail is the least
                            // information-dense thing in this column.
                            Layout.preferredHeight: visible
                                ? Math.min(Math.round(width * 9 / 16), Math.round(150 * panel.uiScale))
                                : 0
                            visible: root.heroTrailer !== null
                            radius: Style.cornerRadius
                            color: Qt.darker(Color.foreground, 2.4)
                            border.width: 1
                            border.color: trailerMouse.containsMouse
                                          ? Color.accent
                                          : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)
                            clip: true

                            Image {
                                anchors.fill: parent
                                source: root.trailerThumbPath
                                visible: source !== ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize.width: Math.round(width)
                                sourceSize.height: Math.round(height)
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "black"
                                opacity: trailerMouse.containsMouse ? 0.30 : 0.50
                                Behavior on opacity { NumberAnimation { duration: 140 } }
                            }
                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 6
                                Text {
                                    text: "\uf04b"
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.title)
                                    color: trailerMouse.containsMouse ? Color.accent : "white"
                                }
                                Text {
                                    text: "Watch Trailer"
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption)
                                    font.bold: true
                                    color: trailerMouse.containsMouse ? Color.accent : "white"
                                }
                            }
                            Text {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 6
                                textFormat: Text.PlainText
                                text: root.heroTrailer ? root.sanitize(root.heroTrailer.name || "") : ""
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption - 1)
                                color: Qt.rgba(1, 1, 1, 0.8)
                            }
                            MouseArea {
                                id: trailerMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                scrollGestureEnabled: false
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.playTrailer()
                            }
                        }

                        // ---- ratings ----
                        // A 2x2 grid of score tiles rather than a chip row: the number is what
                        // is being read, so it leads and a caption says what it means.
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: 6
                            rowSpacing: 6
                            visible: root.details !== null

                            OmaCineRatingBadge {
                                Layout.fillWidth: true
                                visible: String(root.details && root.details.imdbRatingValue || "") !== ""
                                logo: "imdb.png"
                                label: "IMDb"
                                caption: "IMDb SCORE"
                                value: String(root.details && root.details.imdbRatingValue || "")
                                background: "#F5C518"
                                textColor: "#000000"
                                uiScale: panel.uiScale
                                textScale: root.textScale
                                uiFont: root.uiFont
                            }

                            OmaCineRatingBadge {
                                Layout.fillWidth: true
                                visible: root.mdbRatings !== null && root.mdbRatings.metacritic !== null
                                logo: "metacritic.png"
                                label: "metacritic"
                                caption: "METASCORE"
                                value: root.mdbRatings ? String(root.mdbRatings.metacritic) : ""
                                background: !root.mdbRatings ? "transparent"
                                           : root.mdbRatings.metacriticBand === "high" ? "#66CC33"
                                           : root.mdbRatings.metacriticBand === "mixed" ? "#FFCC33" : "#FF6874"
                                textColor: "#000000"
                                uiScale: panel.uiScale
                                textScale: root.textScale
                                uiFont: root.uiFont
                            }

                            OmaCineRatingBadge {
                                Layout.fillWidth: true
                                visible: root.mdbRatings !== null && root.mdbRatings.tomatoes !== null
                                logo: (root.mdbRatings && root.mdbRatings.tomatoesFresh) ? "tomato_fresh.png" : "tomato_rotten.png"
                                label: "RT"
                                caption: "TOMATOMETER"
                                value: root.mdbRatings ? root.mdbRatings.tomatoes + "%" : ""
                                background: (root.mdbRatings && root.mdbRatings.tomatoesFresh) ? "#FA320A" : "#4C9A2A"
                                textColor: "#FFFFFF"
                                uiScale: panel.uiScale
                                textScale: root.textScale
                                uiFont: root.uiFont
                            }

                            OmaCineRatingBadge {
                                Layout.fillWidth: true
                                visible: root.mdbRatings !== null && root.mdbRatings.tomatoesAudience !== null
                                logo: (root.mdbRatings && root.mdbRatings.tomatoesAudience >= 60) ? "audience_fresh.png" : "audience_rotten.png"
                                label: "Audience"
                                caption: "USER APPROVAL"
                                value: root.mdbRatings ? root.mdbRatings.tomatoesAudience + "%" : ""
                                background: "#2A2A2A"
                                textColor: "#FFFFFF"
                                uiScale: panel.uiScale
                                textScale: root.textScale
                                uiFont: root.uiFont
                            }
                        }

                        // ---- theme override ----
                        // ThemerrDB is community-submitted: some titles have no
                        // entry and some point at videos since removed. This is
                        // the local fix for both.
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            visible: root.settings.themeSongs === true && root.currentId !== ""

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Button {
                                    text: root.themeEditOpen ? "Cancel" : "\u266A  Set theme"
                                    tooltipText: "Pin a YouTube link as this title's theme"
                                    onClicked: {
                                        root.themeEditOpen = !root.themeEditOpen;
                                        root.themeEditNote = "";
                                        root.themeEditText = "";
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    visible: root.themeEditNote !== ""
                                    text: root.themeEditNote
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: Math.round(150 * panel.uiScale)
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.small)
                                    color: Color.accent
                                }
                            }

                            TextField {
                                id: themeUrlField
                                Layout.fillWidth: true
                                visible: root.themeEditOpen
                                text: root.themeEditText
                                placeholderText: "https://www.youtube.com/watch?v=\u2026"
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.small)
                                onTextChanged: root.themeEditText = text
                                onAccepted: root.saveThemeUrl(text.trim())
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                visible: root.themeEditOpen
                                spacing: 6
                                Button {
                                    text: "Save"
                                    enabled: root.themeEditText.trim() !== ""
                                    onClicked: root.saveThemeUrl(root.themeEditText.trim())
                                }
                                Button {
                                    text: "Use ThemerrDB"
                                    tooltipText: "Remove the pinned link for this title"
                                    onClicked: root.saveThemeUrl("")
                                }
                            }
                        }
                    }

                    // info column
                    // The details column has to grow: expanding the stream list must push
                    // "More Like This" down and scroll, not clip behind it.
                    Flickable {
                        id: detailsScroll
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: detailsContent.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 900
                        maximumFlickVelocity: 6000

                        // Qt's Wayland touchpad path supplies smooth pixel deltas here, but
                        // does not start a Flickable flick on release. Preserve native
                        // one-for-one tracking, then continue with the velocity measured
                        // from the final gesture updates.
                        property real touchpadVelocityY: 0
                        property double touchpadLastMs: 0
                        property bool touchpadTracking: false
                        property real pendingTouchpadVelocityY: 0

                        Timer {
                            id: detailsTouchpadFlickLaunch
                            interval: 0
                            repeat: false
                            onTriggered: {
                                const velocity = detailsScroll.pendingTouchpadVelocityY
                                const maximumPos = Math.max(0, detailsScroll.contentHeight - detailsScroll.height)
                                const canContinue = (velocity < 0 && detailsScroll.contentY < maximumPos)
                                                            || (velocity > 0 && detailsScroll.contentY > 0)
                                detailsScroll.pendingTouchpadVelocityY = 0
                                if (canContinue)
                                    detailsScroll.flick(0, velocity)
                            }
                        }

                        WheelHandler {
                            target: null
                            blocking: false
                            orientation: Qt.Vertical
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: function(event) {
                                const now = Date.now()
                                const delta = event.pixelDelta.y

                                if (delta !== 0) {
                                    const elapsed = now - detailsScroll.touchpadLastMs
                                    const instantaneousVelocity = elapsed > 0 ? delta * 1000 / elapsed : 0
                                    const stale = !detailsScroll.touchpadTracking || elapsed > 80
                                    const reversed = detailsScroll.touchpadVelocityY !== 0
                                            && instantaneousVelocity * detailsScroll.touchpadVelocityY < 0

                                    if (instantaneousVelocity !== 0) {
                                        if (stale || reversed)
                                            detailsScroll.touchpadVelocityY = instantaneousVelocity
                                        else
                                            detailsScroll.touchpadVelocityY = detailsScroll.touchpadVelocityY * 0.65 + instantaneousVelocity * 0.35
                                    }
                                    detailsScroll.touchpadLastMs = now
                                    detailsScroll.touchpadTracking = true
                                }

                                if (event.phase === Qt.ScrollEnd && detailsScroll.touchpadTracking) {
                                    const releaseAge = now - detailsScroll.touchpadLastMs
                                    let velocity = releaseAge <= 100 ? detailsScroll.touchpadVelocityY * 1.25 : 0
                                    velocity = Math.max(-detailsScroll.maximumFlickVelocity,
                                                        Math.min(detailsScroll.maximumFlickVelocity, velocity))
                                    detailsScroll.pendingTouchpadVelocityY = Math.abs(velocity) >= 180 ? velocity : 0
                                    detailsScroll.touchpadVelocityY = 0
                                    detailsScroll.touchpadLastMs = 0
                                    detailsScroll.touchpadTracking = false
                                    if (detailsScroll.pendingTouchpadVelocityY !== 0)
                                        detailsTouchpadFlickLaunch.restart()
                                }
                            }
                        }
                        ScrollBar.vertical: OmaCineScrollBar { uiScale: panel.uiScale }

                        ColumnLayout {
                            id: detailsContent
                            width: detailsScroll.width
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Image {
                                    Layout.preferredWidth: Math.round(230 * panel.uiScale)
                                    Layout.preferredHeight: Math.round(54 * panel.uiScale)
                                    visible: root.currentLogo !== ""
                                    source: root.currentLogo
                                    fillMode: Image.PreserveAspectFit
                                    horizontalAlignment: Image.AlignLeft
                                    asynchronous: true
                                }
                                Item { Layout.fillWidth: true; visible: root.currentLogo !== "" }
                                Text {
                                    Layout.fillWidth: true
                                    visible: root.currentLogo === ""
                                    textFormat: Text.PlainText
                                    text: root.currentTitle
                                    elide: Text.ElideRight
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.title)
                                    font.bold: true
                                    color: Color.foreground
                                }
                                Button {
                                    // Hidden rather than disabled when a title has no
                                    // reviews, which is roughly a third of them.
                                    visible: root.tmdbReviews.length > 0
                                    text: "\u2605 Reviews (" + root.tmdbReviews.length + ")"
                                    tooltipText: "What viewers wrote about this title"
                                    selected: root.reviewsOpen
                                    fontSize: root.fs(Style.font.caption)
                                    onClicked: root.reviewsOpen = !root.reviewsOpen
                                }
                                Button {
                                    text: root.libraryBusy ? "Updating…" : root.currentInLibrary ? "✓ In My Library" : "+ My Library"
                                    tooltipText: root.currentInLibrary ? "Remove this title from My Library" : "Add this title to My Library"
                                    selected: root.currentInLibrary
                                    enabled: root.details !== null && !root.libraryBusy
                                    fontSize: root.fs(Style.font.caption)
                                    onClicked: root.toggleCurrentLibrary()
                                }
                                Button {
                                    text: "\u2190 Back"
                                    fontSize: root.fs(Style.font.caption)
                                    onClicked: root.backFromDetails()
                                }
                            }

                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: {
                                    if (!root.details) return "";
                                    var parts = [];
                                    var year = root.details.year ? String(root.details.year) : (root.details.releaseDate ? String(root.details.releaseDate).slice(0, 4) : "");
                                    if (year) parts.push(year);
                                    if (root.details.genre) parts.push(root.details.genre);
                                    if (root.details.duration) parts.push(root.details.duration);
                                    if (root.details.imdbRatingValue) parts.push("\u2605 " + root.details.imdbRatingValue);
                                    if (root.details.language) parts.push(root.details.language);
                                    if (root.details.audios) parts.push(root.details.audios);
                                    if (root.details.prints) parts.push(root.details.prints);
                                    return parts.join("  \u2022  ");
                                }
                                wrapMode: Text.WordWrap
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption)
                                color: Qt.darker(Color.foreground, 1.4)
                            }

                            Text {
                                id: plotText
                                Layout.fillWidth: true
                                // One line box, derived rather than hardcoded: the old fixed
                                // 56px did not scale with the text-size setting, so at a large
                                // scale it no longer held two lines and the column squeezed
                                // the plot down to one and elided it.
                                readonly property int lineBox: Math.round(root.fs(Style.font.bodySmall) * 1.45)
                                Layout.minimumHeight: lineBox * 2
                                Layout.preferredHeight: lineBox * 3
                                maximumLineCount: 3
                                textFormat: Text.PlainText
                                text: (root.details && (root.details.intro || root.details.description || root.details.contentRating || "")) || ""
                                wrapMode: Text.WordWrap
                                elide: Text.ElideRight
                                font.family: root.uiFont
                                // This is the one genuine paragraph on the page, so it is set
                                // for reading: a step up from caption size and the extra
                                // leading prose needs. Everything else here is a label.
                                font.pixelSize: root.fs(Style.font.bodySmall)
                                lineHeight: 1.45
                                lineHeightMode: Text.ProportionalHeight
                                color: Qt.lighter(Color.foreground, 1.05)
                            }

                            // ---- primary action ----
                            // The play control used to sit small in the bottom
                            // right, below everything. It is the one thing this
                            // page exists for, so it leads: full-height accent
                            // button, with the source summary as a chip beside
                            // it that opens the same picker as before.
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 6
                                Layout.bottomMargin: 2
                                spacing: 10
                                visible: root.details !== null

                                Rectangle {
                                    id: primaryPlay
                                    Layout.preferredHeight: Math.round(40 * panel.uiScale * Math.max(1, root.textScale * 0.8))
                                    Layout.preferredWidth: playRow.implicitWidth + 34
                                    radius: Math.round(6 * panel.uiScale)
                                    color: !primaryPlay.ready ? Qt.darker(Color.foreground, 2.6)
                                         : playHover.containsMouse ? Qt.lighter(Color.accent, 1.15)
                                         : Color.accent
                                    Behavior on color { ColorAnimation { duration: 110 } }

                                    readonly property bool ready:
                                        root.selStream >= 0 && !root.playing && !root.streamConnecting && !root.busy
                                    readonly property real resumeAt: root.resumePositionFor(
                                        root.currentProvider, root.currentId,
                                        root.isSeries ? root.curSeason : 0,
                                        root.isSeries ? root.curEp : 0)

                                    RowLayout {
                                        id: playRow
                                        anchors.centerIn: parent
                                        spacing: 9
                                        Text {
                                            text: "\u25B6"
                                            font.pixelSize: root.fs(Style.font.body)
                                            color: primaryPlay.ready ? Color.popups.background
                                                                     : Qt.darker(Color.foreground, 1.5)
                                        }
                                        Text {
                                            text: {
                                                var what = root.isSeries && root.curEp
                                                    ? " S" + root.curSeason + " E" + root.curEp : "";
                                                return primaryPlay.resumeAt >= 15
                                                    ? "RESUME" + what + "  \u00B7  " + root.fmtDur(primaryPlay.resumeAt)
                                                    : "PLAY" + what;
                                            }
                                            font.family: root.uiFont
                                            font.pixelSize: root.fs(Style.font.subtitle)
                                            font.weight: Font.Bold
                                            color: primaryPlay.ready ? Color.popups.background
                                                                     : Qt.darker(Color.foreground, 1.5)
                                        }
                                    }

                                    MouseArea {
                                        id: playHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: primaryPlay.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: if (primaryPlay.ready) root.playExternal()
                                    }
                                }

                                // Source summary doubles as the picker toggle, so
                                // the quality you are about to get is readable
                                // without opening anything.
                                Rectangle {
                                    Layout.preferredHeight: primaryPlay.Layout.preferredHeight
                                    Layout.preferredWidth: sourceRow.implicitWidth + 26
                                    radius: Math.round(6 * panel.uiScale)
                                    color: sourceHover.containsMouse
                                         ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.16)
                                         : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.09)
                                    border.width: 1
                                    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)
                                    visible: root.streams.length > 0

                                    RowLayout {
                                        id: sourceRow
                                        anchors.centerIn: parent
                                        spacing: 8
                                        Text {
                                            text: {
                                                var s = root.selStream >= 0 ? root.streams[root.selStream] : null;
                                                var bits = [root.streams.length + " sources"];
                                                if (s && s.resolution) bits.push(s.resolution + "p");
                                                if (s && s.mediaLabel) bits.push(root.friendlyText(s.mediaLabel));
                                                return bits.join("  \u00B7  ");
                                            }
                                            font.family: root.uiFont
                                            font.pixelSize: root.fs(Style.font.caption)
                                            color: Color.foreground
                                        }
                                        Text {
                                            text: root.streamPickerOpen ? "\u25B2" : "\u25BC"
                                            font.pixelSize: root.fs(Style.font.caption - 2)
                                            color: Qt.darker(Color.foreground, 1.4)
                                        }
                                    }
                                    MouseArea {
                                        id: sourceHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.streamPickerOpen = !root.streamPickerOpen
                                    }
                                }

                                Item { Layout.fillWidth: true }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: root.tmdbCast.length > 0
                                text: "Cast"
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption)
                                font.bold: true
                                color: Qt.darker(Color.foreground, 1.25)
                            }

                            ListView {
                                flickDeceleration: 900
                                maximumFlickVelocity: 6000
                                ScrollBar.horizontal: OmaCineScrollBar { uiScale: panel.uiScale }
                                Layout.fillWidth: true
                                Layout.preferredHeight: root.tmdbCast.length > 0 ? Math.round(112 * panel.uiScale) : 0
                                visible: root.tmdbCast.length > 0
                                orientation: ListView.Horizontal
                                spacing: Math.round(10 * panel.uiScale)
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                model: root.tmdbCast

                                delegate: Item {
                                    width: Math.round(66 * panel.uiScale)
                                    height: ListView.view.height
                                    property bool hot: castMouse.containsMouse

                                    Column {
                                        anchors.fill: parent
                                        spacing: Math.round(4 * panel.uiScale)

                                        Rectangle {
                                            width: Math.round(60 * panel.uiScale)
                                            height: width
                                            radius: width / 2
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            color: Color.popups.background
                                            border.width: parent.parent.hot ? 2 : 1
                                            border.color: parent.parent.hot ? Color.accent
                                                                            : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)
                                            clip: true
                                            Image {
                                                anchors.fill: parent
                                                anchors.margins: 1
                                                source: root.imageSource(modelData.image || "")
                                                // Decode at draw size; full-resolution posters are what stall scrolling.
                                                sourceSize.width: Math.round(width)
                                                sourceSize.height: Math.round(height)
                                                fillMode: Image.PreserveAspectCrop
                                                asynchronous: true
                                                cache: true
                                                visible: source !== ""
                                            }
                                            Text {
                                                anchors.centerIn: parent
                                                visible: root.imageSource(modelData.image || "") === ""
                                                text: String(modelData.name || "?").charAt(0).toUpperCase()
                                                font.family: root.uiFont
                                                font.pixelSize: root.fs(Style.font.title)
                                                font.bold: true
                                                color: Qt.darker(Color.foreground, 1.5)
                                            }
                                        }
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            textFormat: Text.PlainText
                                            text: modelData.name || ""
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                            font.family: root.uiFont
                                            font.pixelSize: root.fs(Style.font.caption - 1)
                                            // The actor is the thing being looked up, so it
                                            // carries the weight; the character recedes.
                                            font.weight: Font.DemiBold
                                            color: parent.parent.hot ? Color.accent : Color.foreground
                                        }
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            textFormat: Text.PlainText
                                            text: modelData.role || ""
                                            elide: Text.ElideRight
                                            maximumLineCount: 1
                                            font.family: root.uiFont
                                            font.pixelSize: root.fs(Style.font.caption - 2)
                                            color: Qt.darker(Color.foreground, 1.7)
                                            opacity: 0.85
                                        }
                                    }
                                    MouseArea {
                                        id: castMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        scrollGestureEnabled: false
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.openPerson(modelData.id, modelData.name)
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: root.tmdbCrew.length > 0
                                textFormat: Text.PlainText
                                text: "Crew: " + root.tmdbCrew.slice(0, 6).map(function(person) {
                                    return person.name + (person.role ? " (" + person.role + ")" : "");
                                }).join("  •  ")
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption - 1)
                                color: Qt.darker(Color.foreground, 1.35)
                            }

                            // MovieBox-Tui prefers original audio and lets the user
                            // explicitly choose any advertised dub variant.
                            Flow {
                                Layout.fillWidth: true
                                visible: root.audioOptions.length > 1
                                spacing: 6
                                Text {
                                    text: "Audio:"
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption)
                                    font.bold: true
                                    color: Color.accent
                                    height: implicitHeight + 8
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Repeater {
                                    model: root.audioOptions
                                    Button {
                                        text: root.audioName(modelData)
                                        fontSize: root.fs(Style.font.caption)
                                        selected: index === root.selectedAudio
                                        enabled: !root.busy
                                        onClicked: root.selectAudio(index)
                                    }
                                }
                            }

                            // Seasons stay compact; TMDB-backed episodes become visual cards.
                            RowLayout {
                                Layout.fillWidth: true
                                visible: root.isSeries
                                spacing: 8
                                Dropdown {
                                    width: 150
                                    showLabel: false
                                    value: String(root.curSeason)
                                    options: root.seasonOptions()
                                    enabled: root.seasons.length > 1 && !root.busy
                                    onChanged: function(value) { root.selectSeason(value); }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.maxEp + (root.maxEp === 1 ? " episode" : " episodes")
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption)
                                    color: Qt.darker(Color.foreground, 1.35)
                                }
                            }

                            ListView {
                                flickDeceleration: 900
                                maximumFlickVelocity: 6000
                                ScrollBar.horizontal: OmaCineScrollBar { uiScale: panel.uiScale }
                                id: episodeRail
                                Layout.fillWidth: true
                                Layout.preferredHeight: visible ? Math.round(82 * panel.uiScale) : 0
                                visible: root.isSeries && root.tmdbEpisodes.length > 0
                                orientation: ListView.Horizontal
                                spacing: 7
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                model: root.tmdbEpisodes
                                delegate: Rectangle {
                                    required property var modelData
                                    width: Math.round(190 * panel.uiScale)
                                    height: episodeRail.height
                                    radius: Style.cornerRadius
                                    color: Number(modelData.episode || 0) === root.curEp
                                         ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                                         : (Color.surface ?? Qt.darker(Color.foreground, 2.15))
                                    border.width: Number(modelData.episode || 0) === root.curEp ? 2 : 0
                                    border.color: Color.accent
                                    clip: true
                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: 5
                                        spacing: 7
                                        Rectangle {
                                            width: Math.round(92 * panel.uiScale)
                                            height: parent.height
                                            radius: Style.cornerRadius
                                            color: Qt.darker(Color.foreground, 2.2)
                                            clip: true
                                            Image { anchors.fill: parent; source: root.imageSource(modelData.still || ""); fillMode: Image.PreserveAspectCrop; asynchronous: true }
                                        }
                                        Column {
                                            width: parent.width - Math.round(104 * panel.uiScale)
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 3
                                            Text { width: parent.width; text: "E" + modelData.episode + "  " + (modelData.name || "Episode"); elide: Text.ElideRight; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 1); font.bold: true; color: Color.foreground }
                                            Text { width: parent.width; text: Number(modelData.runtime || 0) > 0 ? modelData.runtime + " min" : (modelData.airDate || ""); elide: Text.ElideRight; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 2); color: Color.accent }
                                            Text { width: parent.width; text: root.isEpisodeWatched(root.curSeason, modelData.episode) ? "Watched ✓" : "Select episode"; elide: Text.ElideRight; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 2); color: Qt.darker(Color.foreground, 1.35) }
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.curEp = Number(modelData.episode || 1);
                                            root.loadStreams(root.curSeason, root.curEp);
                                        }
                                    }
                                }
                            }

                            // Fallback until TMDB episode metadata arrives.
                            Flow {
                                Layout.fillWidth: true
                                visible: root.isSeries && root.tmdbEpisodes.length === 0
                                spacing: 6
                                Repeater {
                                    model: root.maxEp
                                    Button {
                                        text: root.episodeProgressLabel(root.curSeason, index + 1)
                                        fontSize: root.fs(Style.font.caption)
                                        selected: (index + 1) === root.curEp
                                        onClicked: {
                                            root.curEp = index + 1;
                                            root.loadStreams(root.curSeason, index + 1);
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: false
                                Layout.minimumHeight: visible ? Math.round(76 * panel.uiScale) : 0
                                Layout.preferredHeight: visible ? Math.round(76 * panel.uiScale) : 0
                                Layout.maximumHeight: visible ? Math.round(76 * panel.uiScale) : 0
                                visible: root.isSeries && episodeInfo !== null
                                spacing: 8
                                clip: true
                                property var episodeInfo: root.currentEpisodeInfo()
                                Rectangle {
                                    Layout.minimumWidth: Math.round(120 * panel.uiScale)
                                    Layout.preferredWidth: Math.round(120 * panel.uiScale)
                                    Layout.maximumWidth: Math.round(120 * panel.uiScale)
                                    Layout.minimumHeight: Math.round(68 * panel.uiScale)
                                    Layout.preferredHeight: Math.round(68 * panel.uiScale)
                                    Layout.maximumHeight: Math.round(68 * panel.uiScale)
                                    Layout.fillHeight: false
                                    Layout.alignment: Qt.AlignTop
                                    radius: Style.cornerRadius
                                    color: Qt.darker(Color.foreground, 2.1)
                                    clip: true
                                    Image {
                                        anchors.fill: parent
                                        source: root.imageSource(parent.parent.episodeInfo ? parent.parent.episodeInfo.still : "")
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: false
                                    Layout.alignment: Qt.AlignTop
                                    spacing: 2
                                    Text {
                                        Layout.fillWidth: true
                                        textFormat: Text.PlainText
                                        text: {
                                            var ep = parent.parent.episodeInfo;
                                            if (!ep) return "";
                                            var suffix = [];
                                            if (ep.airDate) suffix.push(ep.airDate);
                                            if (Number(ep.runtime || 0) > 0) suffix.push(ep.runtime + " min");
                                            if (Number(ep.rating || 0) > 0) suffix.push("★ " + ep.rating);
                                            return root.episodeCode(root.curSeason, root.curEp) + " • " + ep.name
                                                 + (suffix.length ? "  •  " + suffix.join("  •  ") : "");
                                        }
                                        elide: Text.ElideRight
                                        font.family: root.uiFont
                                        font.pixelSize: root.fs(Style.font.caption)
                                        font.bold: true
                                        color: Color.accent
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        textFormat: Text.PlainText
                                        text: parent.parent.episodeInfo ? (parent.parent.episodeInfo.overview || "No episode summary available.") : ""
                                        wrapMode: Text.WordWrap
                                        elide: Text.ElideRight
                                        maximumLineCount: 3
                                        font.family: root.uiFont
                                        font.pixelSize: root.fs(Style.font.caption - 1)
                                        color: Qt.darker(Color.foreground, 1.35)
                                    }
                                }
                            }

                            PanelSeparator { Layout.fillWidth: true }

                            // streams
                            Text {
                                Layout.fillWidth: true
                                text: "Available streams" + (root.isSeries ? (" \u2014 S" + root.curSeason + (root.curEp ? " E" + root.curEp : "")) : "")
                                font.family: root.uiFont
                                font.pixelSize: root.fs(Style.font.caption)
                                font.bold: true
                                color: Color.accent
                            }

                            OmaCineStreamPicker {
                                Layout.fillWidth: true
                                Layout.preferredHeight: visible ? implicitHeight : 0
                                visible: root.streams.length > 0
                                streams: root.streams
                                selectedIndex: root.selStream
                                expanded: root.streamPickerOpen
                                loading: root.streamsBusy
                                qualityLimit: root.streamQualityLimit
                                sizeLimit: root.streamSizeLimit
                                sortMode: root.streamSortMode
                                uiScale: panel.uiScale
                                textScale: root.textScale
                                onSelected: function(originalIndex) {
                                    root.selectStream(originalIndex);
                                    root.streamPickerOpen = false;
                                }
                                onExpandedRequested: function(value) { root.streamPickerOpen = value; }
                                onQualityLimitRequested: function(value) { root.setStreamQualityLimit(value); }
                                onSizeLimitRequested: function(value) { root.setStreamSizeLimit(value); }
                                onSortModeRequested: function(value) { root.streamSortMode = value; }
                            }
                            // streams placeholder — visible when empty (loading vs no streams)
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: visible ? Math.round(64 * panel.uiScale) : 0
                                visible: root.streams.length === 0
                                Text {
                                    anchors.centerIn: parent
                                    width: parent.width - 20
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    wrapMode: Text.WordWrap
                                    textFormat: Text.PlainText
                                    text: root.streamsBusy
                                          ? (root.isSeries ? ("Loading streams for S" + root.curSeason + "E" + (root.curEp || 1) + " \u2026") : "Loading streams \u2026")
                                          : (root.isSeries ? ("No streams for S" + root.curSeason + "E" + (root.curEp || 1) + " — tap again to retry") : "No streams — tap again to retry")
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption)
                                    color: root.streamsBusy ? Color.accent : Qt.darker(Color.foreground, 1.4)
                                    opacity: root.streamsBusy ? 0.9 : 0.8
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: !root.streamsBusy && root.currentId !== ""
                                    onClicked: root.loadStreams(root.isSeries ? root.curSeason : 0, root.isSeries ? root.curEp : 0)
                                }
                            }

                            // "More like this" — TMDB behavioural recommendations first, then its
                            // content-based matches. Cards open like any other, and Back returns here.
                            OmaCineMediaRail {
                                Layout.fillWidth: true
                                Layout.preferredHeight: visible ? Math.round(196 * panel.uiScale) : 0
                                visible: detailRelatedModel.count > 0
                                title: "More Like This"
                                subtitle: root.currentTitle ? "Because you opened " + root.currentTitle : ""
                                mediaModel: detailRelatedModel
                                uiScale: panel.uiScale
                                textScale: root.textScale
                                uiFont: root.uiFont
                                urlResolver: root.imageSource
                                onActivated: function(item) { root.openItem(item); }
                                onPreviewRequested: function(item) {
                                    if (root.settings.railHoverPreview !== true) return;
                                    root.prefetchDetails(item.id, item.provider);
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                visible: root.upNextText !== ""
                                spacing: 6
                                Text {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: root.upNextText
                                    elide: Text.ElideRight
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption - 2)
                                    color: Color.accent
                                }
                                Button {
                                    text: "Play Now"
                                    visible: root.nextEpisodeCountdown > 0 && !root.nextEpisodeCancelled
                                    enabled: !mpvCommandProc.running
                                    fontSize: root.fs(Style.font.caption)
                                    selected: true
                                    onClicked: root.playNextEpisodeNow()
                                }
                                Button {
                                    text: "Cancel"
                                    visible: root.nextEpisodeCountdown > 0 && !root.nextEpisodeCancelled
                                    enabled: !mpvCommandProc.running
                                    fontSize: root.fs(Style.font.caption)
                                    onClicked: root.cancelNextEpisode()
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Layout.bottomMargin: 10
                                Dropdown {
                                    width: 190
                                    showLabel: false
                                    visible: root.selStream >= 0
                                    value: root.selectedSubtitle
                                    options: root.subtitleOptions()
                                    enabled: root.subs.length > 0
                                    onChanged: function(nextValue) { root.selectSubtitle(nextValue) }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: (root.streamHealthText ? "●  " : "") + (root.streamHealthText || root.statusText)
                                    elide: Text.ElideRight
                                    font.family: root.uiFont
                                    font.pixelSize: root.fs(Style.font.caption - 2)
                                    color: root.streamHealthState === "ready" || root.streamHealthState === "receiving"
                                         ? Color.accent
                                         : root.streamHealthText ? Color.foreground : Qt.darker(Color.foreground, 1.4)
                                }
                            }
                            Item { Layout.preferredHeight: 4 }
                        }
                    }
                }
            }

            // ---- embedded player ----
            Item {
                anchors.fill: parent
                visible: root.view === "player"
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            Layout.fillWidth: true
                            textFormat: Text.PlainText
                            text: root.playerTitle || "Player"
                            elide: Text.ElideRight
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.title)
                            font.bold: true
                            color: Color.foreground
                        }
                        Button {
                            text: root.playerFullscreen ? "\u00D7 Full" : "\u26F6 Full"
                            tooltipText: root.playerFullscreen ? "Exit fullscreen" : "Fullscreen"
                            fontSize: root.fs(Style.font.caption)
                            onClicked: root.playerFullscreen = !root.playerFullscreen
                        }
                        Button {
                            text: "\u2190 Back"
                            fontSize: root.fs(Style.font.caption)
                            onClicked: { root.stopEmbedded(); root.goHome(); root.playerFullscreen = false; }
                        }
                        Button {
                            text: "X"
                            tooltipText: "Close"
                            fontSize: root.fs(Style.font.body)
                            horizontalPadding: 10
                            verticalPadding: 5
                            onClicked: root.close()
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: Style.cornerRadius
                        color: "black"
                        clip: true
                        VideoOutput {
                            id: embeddedVideoOutput
                            anchors.fill: parent
                            fillMode: VideoOutput.PreserveAspectFit
                            smooth: true
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: embeddedPlayer.playbackState !== MediaPlayer.PlayingState && embeddedPlayer.playbackState !== MediaPlayer.PausedState
                            text: root.embeddedPlaying ? "Buffering \u2026" : ""
                            font.family: root.uiFont
                            font.pixelSize: root.fs(32)
                            color: "white"
                            opacity: 0.7
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            text: embeddedPlayer.playbackState === MediaPlayer.PlayingState ? "\u23F8 Pause" : "\u25B6 Play"
                            enabled: root.playerUrl !== ""
                            onClicked: {
                                if (embeddedPlayer.playbackState === MediaPlayer.PlayingState) embeddedPlayer.pause();
                                else embeddedPlayer.play();
                            }
                        }
                        PanelSlider {
                            id: playerSlider
                            Layout.fillWidth: true
                            bar: root.bar
                            minimum: 0
                            maximum: embeddedPlayer.duration > 0 ? embeddedPlayer.duration : 1
                            value: embeddedPlayer.position
                            enabled: embeddedPlayer.seekable
                            onMoved: function(v) { embeddedPlayer.position = v; }
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: {
                                function fmt(ms) {
                                    if (!ms || ms < 0) return "0:00";
                                    var s = Math.floor(ms/1000);
                                    var m = Math.floor(s/60);
                                    var sec = s % 60;
                                    return m + ":" + (sec < 10 ? "0"+sec : sec);
                                }
                                return fmt(embeddedPlayer.position) + " / " + fmt(embeddedPlayer.duration);
                            }
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption - 1)
                            color: Qt.darker(Color.foreground, 1.2)
                        }
                        Button {
                            text: "mpv"
                            tooltipText: "Open same stream in mpv"
                            enabled: root.selStream >= 0
                            onClicked: root.playExternal()
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: root.statusText
                        elide: Text.ElideRight
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption - 2)
                        color: Qt.darker(Color.foreground, 1.4)
                    }
                }
            }
        }
    }

        // ---- audience reviews ----
        // A modal rather than another rail: TMDB carries one or two reviews for
        // most titles and none for about a third, so a permanent section would
        // be empty more often than not. Opened from the header, it also keeps
        // the details column - already the tightest space in the app - untouched.
        MouseArea {
            id: reviewsScrim
            visible: root.reviewsOpen
            anchors.fill: parent
            z: 2000
            hoverEnabled: true
            // Swallow clicks so nothing behind the modal reacts, and close on
            // a click outside the panel.
            onClicked: root.reviewsOpen = false
            onWheel: function(wheel) { wheel.accepted = true }

            Rectangle {
                anchors.fill: parent
                color: "black"
                opacity: 0.55
            }

            Rectangle {
                id: reviewsPanel
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, Math.round(880 * panel.uiScale))
                height: Math.min(parent.height - 80, Math.round(620 * panel.uiScale))
                radius: Style.cornerRadius
                color: Color.popups.background
                opacity: Number(root.settings.reviewOpacity)
                border.width: 1
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
                clip: true

                // Clicks inside must not fall through to the scrim and close it.
                // Absorb clicks so they do not reach the scrim and close the
                // modal; wheel events still reach the list below.
                MouseArea {
                    anchors.fill: parent
                    onClicked: {}
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 12

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            text: "Audience Reviews"
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.heading)
                            font.bold: true
                            color: Color.accent
                        }
                        Text {
                            text: {
                                var n = root.tmdbReviews.length;
                                var sum = 0, count = 0;
                                for (var i = 0; i < n; i++) {
                                    var r = Number(root.tmdbReviews[i].rating);
                                    if (!isNaN(r) && r > 0) { sum += r; count++; }
                                }
                                var label = n + (n === 1 ? " review" : " reviews");
                                return count > 0 ? label + "  \u2022  avg \u2605 " + (sum / count).toFixed(1) : label;
                            }
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption)
                            color: Qt.darker(Color.foreground, 1.4)
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: "Opacity"
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption - 1)
                            color: Qt.darker(Color.foreground, 1.6)
                        }
                        PanelSlider {
                            Layout.preferredWidth: Math.round(110 * panel.uiScale)
                            bar: root.bar
                            minimum: 0.60; maximum: 1.0
                            value: Number(root.settings.reviewOpacity)
                            onMoved: function(v) { root.updateSetting("reviewOpacity", Math.round(v * 100) / 100); }
                        }
                        Button {
                            text: "\u2715"
                            fontSize: root.fs(Style.font.caption)
                            onClicked: root.reviewsOpen = false
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        // TMDB carries no spoiler flag, so a shield here would be
                        // theatre - saying so plainly is more honest.
                        text: "From TMDB contributors. Reviews are not spoiler-flagged \u2014 read with care."
                        wrapMode: Text.WordWrap
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Style.font.caption - 1)
                        color: Qt.darker(Color.foreground, 1.7)
                    }

                    Flickable {
                        id: reviewsFlick
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentHeight: reviewsColumn.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        // Same wheel handling as the other scrolling surfaces:
                        // Qt delivers high-resolution pixel deltas here but never
                        // starts a flick, so the wheel is applied directly.
                        WheelHandler {
                            target: null
                            onWheel: function(event) {
                                var step = event.pixelDelta.y !== 0 ? event.pixelDelta.y
                                         : (event.angleDelta.y / 120) * 90;
                                var maxY = Math.max(0, reviewsFlick.contentHeight - reviewsFlick.height);
                                reviewsFlick.contentY = Math.max(0, Math.min(maxY, reviewsFlick.contentY - step));
                            }
                        }

                        ColumnLayout {
                            id: reviewsColumn
                            width: reviewsFlick.width
                            spacing: 10

                            Repeater {
                                model: root.tmdbReviews
                                delegate: Rectangle {
                                    Layout.fillWidth: true
                                    // Height flows one way: from the content out. Filling the card
                                    // with the layout while sizing the card from the layout loops.
                                    Layout.preferredHeight: reviewCard.implicitHeight + 24
                                    radius: Style.cornerRadius
                                    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
                                    border.width: 1
                                    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)

                                    ColumnLayout {
                                        id: reviewCard
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: 12
                                        spacing: 8

                                        RowLayout {
                                            id: reviewHead
                                            Layout.fillWidth: true
                                            spacing: 8

                                            // Avatars are often absent, so the same
                                            // initial-letter fallback the cast row uses.
                                            Rectangle {
                                                Layout.preferredWidth: Math.round(30 * panel.uiScale)
                                                Layout.preferredHeight: Math.round(30 * panel.uiScale)
                                                radius: width / 2
                                                color: Qt.darker(Color.foreground, 2.2)
                                                clip: true
                                                Image {
                                                    anchors.fill: parent
                                                    source: root.imageSource(modelData.avatar || "")
                                                    visible: status === Image.Ready
                                                    fillMode: Image.PreserveAspectCrop
                                                    asynchronous: true
                                                    sourceSize.width: 60
                                                    sourceSize.height: 60
                                                }
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: String(modelData.author || "?").charAt(0).toUpperCase()
                                                    font.family: root.uiFont
                                                    font.pixelSize: root.fs(Style.font.caption)
                                                    font.bold: true
                                                    color: Qt.darker(Color.foreground, 1.4)
                                                }
                                            }

                                            Text {
                                                text: modelData.author || "Anonymous"
                                                font.family: root.uiFont
                                                font.pixelSize: root.fs(Style.font.caption)
                                                font.weight: Font.DemiBold
                                                color: Color.foreground
                                            }
                                            Text {
                                                visible: modelData.rating !== null && modelData.rating !== undefined
                                                text: "\u2605 " + Number(modelData.rating).toFixed(1) + " / 10"
                                                font.family: root.dataFont
                                                font.pixelSize: root.fs(Style.font.caption - 1)
                                                color: Color.accent
                                            }
                                            Item { Layout.fillWidth: true }
                                            Text {
                                                text: modelData.created || ""
                                                font.family: root.dataFont
                                                font.pixelSize: root.fs(Style.font.caption - 1)
                                                color: Qt.darker(Color.foreground, 1.7)
                                            }
                                        }

                                        Text {
                                            id: reviewBody
                                            Layout.fillWidth: true
                                            textFormat: Text.PlainText
                                            text: modelData.content || ""
                                            wrapMode: Text.WordWrap
                                            // Reviews run from a few hundred to a few
                                            // thousand characters, so they clamp until asked.
                                            maximumLineCount: root.reviewsExpanded[modelData.id] ? 999 : 4
                                            elide: Text.ElideRight
                                            font.family: root.uiFont
                                            font.pixelSize: root.fs(Style.font.bodySmall)
                                            lineHeight: 1.45
                                            lineHeightMode: Text.ProportionalHeight
                                            color: Qt.lighter(Color.foreground, 1.05)
                                        }

                                        Text {
                                            visible: reviewBody.truncated || root.reviewsExpanded[modelData.id] === true
                                            text: root.reviewsExpanded[modelData.id] ? "Show less" : "Read more"
                                            font.family: root.uiFont
                                            font.pixelSize: root.fs(Style.font.caption - 1)
                                            font.underline: readMore.containsMouse
                                            color: Color.accent
                                            MouseArea {
                                                id: readMore
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.toggleReviewExpanded(modelData.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Floating search dropdown: it overlays the spotlight instead of
        // participating in mainColumn and pushing the content downward.
        Rectangle {
            id: suggestionsPanel
            visible: suggestionModel.count > 0
            z: 1000
            x: mainColumn.x + primaryNav.x + searchField.x
            y: mainColumn.y + primaryNav.y + primaryNav.height + 8
            width: searchField.width
            height: suggestionsColumn.implicitHeight + 20
            radius: Style.cornerRadius
            color: Color.popups.background
            border.width: 1
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
            clip: true

            Column {
                id: suggestionsColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 10
                spacing: 2

                Text {
                    width: parent.width
                    height: 28
                    text: "Search Suggestions"
                    textFormat: Text.PlainText
                    verticalAlignment: Text.AlignVCenter
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    color: Qt.darker(Color.foreground, 1.35)
                }

                Repeater {
                    model: suggestionModel
                    Rectangle {
                        required property string name
                        width: suggestionsColumn.width
                        height: 34
                        radius: Math.max(4, Style.cornerRadius - 4)
                        color: suggestionMouse.containsMouse
                               ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                               : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            text: name
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.bodySmall)
                            color: Color.foreground
                        }
                        MouseArea {
                            id: suggestionMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                searchField.text = name;
                                root.doSearch();
                            }
                        }
                    }
                }
            }
        }

}
    // True fullscreen - covers entire screen
    PanelWindow {
        id: fullscreenWindow
        visible: root.playerFullscreen && root.view === "player"
        screen: panel.screen
        color: "black"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore

        VideoOutput {
            id: fullscreenVideoOutput
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
            smooth: true
        }

        Rectangle {
            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
            height: 48; color: "#80000000"; visible: fullscreenWindow.visible
            RowLayout {
                anchors.fill: parent; anchors.margins: 10; spacing: 10
                Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.playerTitle || "Player"; color: "white"; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.title); font.bold: true; elide: Text.ElideRight }
                Button { text: "✕ Exit Full"; fontSize: root.fs(Style.font.caption); onClicked: root.playerFullscreen = false }
                Button { text: "X"; fontSize: root.fs(Style.font.caption); onClicked: root.close() }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
            height: 64; color: "#80000000"; visible: fullscreenWindow.visible
            RowLayout {
                anchors.fill: parent; anchors.margins: 10; spacing: 10
                Button {
                    text: embeddedPlayer.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"
                    onClicked: embeddedPlayer.playbackState === MediaPlayer.PlayingState ? embeddedPlayer.pause() : embeddedPlayer.play()
                }
                PanelSlider {
                    Layout.fillWidth: true; bar: root.bar
                    minimum: 0; maximum: embeddedPlayer.duration > 0 ? embeddedPlayer.duration : 1
                    value: embeddedPlayer.position; enabled: embeddedPlayer.seekable
                    onMoved: function(v) { embeddedPlayer.position = v; }
                }
                Text {
                    textFormat: Text.PlainText
                    text: {
                        function fmt(ms){ if(!ms||ms<0) return "0:00"; var s=Math.floor(ms/1000); var m=Math.floor(s/60); var sec=s%60; return m+":"+(sec<10?"0"+sec:sec); }
                        return fmt(embeddedPlayer.position)+" / "+fmt(embeddedPlayer.duration);
                    }
                    color: "white"; font.family: root.uiFont; font.pixelSize: root.fs(Style.font.caption - 1)
                }
                Button { text: "mpv"; onClicked: { root.playerFullscreen = false; root.playExternal(); } }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onDoubleClicked: root.playerFullscreen = false
        }
    }

    // Esc from any view closes panel; searchField's own Keys handler clears field when focused
    Shortcut {
        sequence: "Escape"
        enabled: root.opened && !searchField.activeFocus
        onActivated: root.close()
        context: Qt.WindowShortcut
    }
    Shortcut { sequence: "Ctrl+1"; enabled: root.opened; onActivated: root.goHome(); context: Qt.WindowShortcut }
    Shortcut { sequence: "Ctrl+2"; enabled: root.opened; onActivated: root.openDiscover(false); context: Qt.WindowShortcut }
    Shortcut { sequence: "Ctrl+3"; enabled: root.opened; onActivated: root.openLibrary(); context: Qt.WindowShortcut }
    Shortcut { sequence: "Ctrl+4"; enabled: root.opened; onActivated: root.openSources(); context: Qt.WindowShortcut }
    Shortcut { sequence: "Ctrl+L"; enabled: root.opened; onActivated: searchField.forceActiveFocus(); context: Qt.WindowShortcut }
}
