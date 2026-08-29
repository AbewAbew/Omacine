import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "tenzin.omamovie"

    visible: true
    readonly property bool playbackActive: panelLoader.item ? panelLoader.item.playing === true : false
    readonly property string playbackLabel: panelLoader.item ? String(panelLoader.item.playbackTitle || "Now Playing") : "Now Playing"
    readonly property real playbackProgress: panelLoader.item && Number(panelLoader.item.playbackDuration || 0) > 0
                                             ? Math.max(0, Math.min(1, Number(panelLoader.item.playbackPosition || 0) / Number(panelLoader.item.playbackDuration))) : 0

    implicitWidth: playbackActive && !vertical ? nowPlayingButton.implicitWidth : button.implicitWidth
    implicitHeight: playbackActive && vertical ? nowPlayingButton.implicitHeight : button.implicitHeight

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property string setupScript: Qt.resolvedUrl("omamovie-setup.sh").toString().replace(/^file:\/\//, "")
    readonly property string pendingOpenMarker: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omamovie/.pending-open"
    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""
    property bool userClickedInstall: false

    function ensureBridge() {
        if (setupProc.running) return;
        root.installing = true;
        root.bridgeError = "";
        setupProc.setupOutput = "";
        setupProc.command = ["bash", root.setupScript];
        setupProc.running = true;
    }

    function injectPanel() {
        var target = panelLoader.item;
        if (!target) return;
        if ("bar" in target) target.bar = root.bar;
        if ("settings" in target) target.settings = root.settings;
        if ("anchorItem" in target) target.anchorItem = button;
        if ("hostWidget" in target) target.hostWidget = root;
    }

    function togglePanel() {
        if (!root.bridgeReady) {
            // The bridge is still downloading (or missing): note that the
            // user wants the panel, and re-open it once installation lands.
            root.userClickedInstall = true;
            touchProc.command = ["touch", root.pendingOpenMarker];
            touchProc.running = true;
            root.ensureBridge();
            return;
        }
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
    }

    // One-shot: a click may have asked for the panel while the bridge was
    // installing (possibly across the shell reload we trigger on a fresh
    // install). If such a marker file exists, open the panel now.
    function consumePendingOpen() {
        markerProc.out = "";
        markerProc.command = ["bash", "-c", "m=\"$1\"; [ -f \"$m\" ] && rm -f \"$m\" && echo OPEN", "_", root.pendingOpenMarker];
        markerProc.running = true;
    }
    function open() {
        if (panelLoader.item && panelLoader.item.openFromHotkey)
            panelLoader.item.openFromHotkey();
    }
    function close() {
        if (panelLoader.item && panelLoader.item.close)
            panelLoader.item.close();
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
            panelLoader.item.closeForPopoutSwitch();
    }

    function showHome(_arg) {
        var target = panelLoader.item;
        if (!target) return;
        target.openFromHotkey();
        target.goHome();
    }

    function showDiscover(_arg) {
        var target = panelLoader.item;
        if (!target) return;
        target.openFromHotkey();
        target.openDiscover(false);
    }

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Process {
        id: setupProc
        property string setupOutput: ""
        property string errorOutput: ""
        stdout: SplitParser {
            onRead: function(data) { setupProc.setupOutput += data + "\n" }
        }
        stderr: SplitParser {
            onRead: function(data) { setupProc.errorOutput += data + "\n" }
        }
        onExited: function(exitCode) {
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady) {
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge installation failed";
                return;
            }
            var out = setupProc.setupOutput;
            var restartScheduled = out.indexOf("OMAMOVIE_RESTART_SHELL=1") !== -1;
            if (restartScheduled) {
                return;
            }
            if (root.userClickedInstall) {
                root.userClickedInstall = false;
                touchProc.command = ["rm", "-f", root.pendingOpenMarker];
                touchProc.running = true;
                Qt.callLater(root.togglePanel);
            }
        }
    }

    Process {
        id: markerProc
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { markerProc.out += data }
        }
        onExited: function(exitCode) {
            if (markerProc.out.indexOf("OPEN") !== -1)
                Qt.callLater(root.togglePanel);
        }
    }

    Process {
        id: touchProc
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        visible: !root.playbackActive || root.vertical
        bar: root.bar
        text: ""
        slotSize: Style.bar.statusSlot
        tooltipText: root.installing ? "OmaCine \u2022 preparing the media bridge \u2026" :
                     (root.bridgeReady ? "OmaCine \u2022 cinematic discovery, library and playback" :
                      (root.bridgeError || "OmaCine \u2022 bridge not installed; click to retry"))
        onPressed: root.togglePanel()
    }

    WidgetButton {
        id: nowPlayingButton
        anchors.fill: parent
        visible: root.playbackActive && !root.vertical
        bar: root.bar
        fixedWidth: 220
        fontSize: Style.font.caption
        text: "▶  " + (root.playbackLabel.length > 22 ? root.playbackLabel.slice(0, 22) + "…" : root.playbackLabel)
        tooltipText: "OmaCine • " + root.playbackLabel
        onPressed: root.togglePanel()

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            height: 2
            color: root.bar ? Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.22)
                            : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.22)
            Rectangle {
                width: parent.width * root.playbackProgress
                height: parent.height
                color: Color.accent
            }
        }
    }


    Component.onCompleted: {
        root.consumePendingOpen();
        root.ensureBridge();
    }
}
