import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
    id: root

    property var streams: []
    property int selectedIndex: -1
    property int rememberedIndex: -1
    property bool expanded: false
    property bool loading: false
    property int qualityLimit: 1080
    property real sizeLimit: 0
    property string sortMode: "balanced"
    property real uiScale: 1.0
    // Text scale from Settings > Interface, handed down by the panel.
    property real textScale: 1.0
    function fs(size) {
        var base = Number(size);
        return Math.max(1, Math.round((isNaN(base) ? 10 : base) * root.textScale));
    }

    signal selected(int originalIndex)
    signal expandedRequested(bool value)
    signal qualityLimitRequested(int value)
    signal sizeLimitRequested(real value)
    signal sortModeRequested(string value)

    function resolutionOf(stream) { return Number(stream && stream.resolution || 0); }
    function sourcesOf(stream) { return Number(stream && (stream.peerCount || stream.seeders) || 0); }
    function sizeOf(stream) { return Number(stream && stream.size || 0); }
    function formatSize(bytes) {
        var value = Number(bytes || 0);
        if (value <= 0) return "";
        if (value >= 1073741824) return (value / 1073741824).toFixed(value >= 10737418240 ? 0 : 1) + " GB";
        return Math.round(value / 1048576) + " MB";
    }
    function releaseName(stream) {
        var lines = String(stream && stream.description || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line || line.indexOf("📅") === 0 || line.indexOf("👤") === 0) continue;
            return line;
        }
        return "";
    }
    function streamTooltip(stream, fallback) {
        var release = root.releaseName(stream);
        return release ? release + "\n" + fallback : fallback;
    }
    function streamLabel(stream) {
        if (!stream) return root.loading ? "Loading available streams…" : "Choose a stream";
        var parts = [];
        var resolution = root.resolutionOf(stream);
        if (resolution) parts.push(resolution + "p");
        var sources = root.sourcesOf(stream);
        if (sources) parts.push(sources + (sources === 1 ? " source" : " sources"));
        var size = root.formatSize(root.sizeOf(stream));
        if (size) parts.push(size);
        if (stream.mediaLabel) parts.push(String(stream.mediaLabel));
        else if (stream.codecName) parts.push(String(stream.codecName).toUpperCase());
        if (stream.sourceLabel) parts.push(String(stream.sourceLabel));
        if (stream.streamBadge) parts.push(String(stream.streamBadge));
        return parts.join("  •  ") || "Stream";
    }
    function filteredStreams() {
        var out = [];
        for (var i = 0; i < root.streams.length; i++) {
            var stream = root.streams[i];
            var resolution = root.resolutionOf(stream);
            var size = root.sizeOf(stream);
            if (root.qualityLimit > 0 && resolution > root.qualityLimit) continue;
            if (root.sizeLimit > 0 && size > root.sizeLimit) continue;
            out.push({ originalIndex: i, stream: stream });
        }
        out.sort(function(left, right) {
            var a = left.stream, b = right.stream;
            if (root.sortMode === "sources") return root.sourcesOf(b) - root.sourcesOf(a);
            if (root.sortMode === "smallest") return root.sizeOf(a) - root.sizeOf(b);
            if (root.sortMode === "quality") return root.resolutionOf(b) - root.resolutionOf(a);
            var quality = root.resolutionOf(b) - root.resolutionOf(a);
            if (quality) return quality;
            var sources = root.sourcesOf(b) - root.sourcesOf(a);
            if (sources) return sources;
            return root.sizeOf(a) - root.sizeOf(b);
        });
        return out;
    }
    function currentStream() {
        return root.selectedIndex >= 0 && root.selectedIndex < root.streams.length
             ? root.streams[root.selectedIndex] : null;
    }
    function rememberedSuffix(index) {
        return index === root.rememberedIndex ? "  •  Last played" : "";
    }

    // Content-sized, not parent-sized: expanding must grow the picker so the
    // details column scrolls, instead of squeezing the list into a fixed box.
    implicitHeight: layout.implicitHeight

    ColumnLayout {
        id: layout
        width: parent.width
        spacing: 7

        Button {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            text: (root.expanded ? "▴  " : "▾  ") + root.streamLabel(root.currentStream())
                + root.rememberedSuffix(root.selectedIndex)
            tooltipText: root.streamTooltip(root.currentStream(),
                root.expanded ? "Close stream choices" : "Compare quality, availability and size")
            selected: true
            leftAlign: true
            enabled: !root.loading && root.streams.length > 0
            onClicked: root.expandedRequested(!root.expanded)
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.expanded
            spacing: 7
            Text {
                text: root.filteredStreams().length + " of " + root.streams.length + " streams"
                font.family: Style.font.family
                font.pixelSize: root.fs(Style.font.caption)
                font.bold: true
                color: Color.accent
            }
            Item { Layout.fillWidth: true }
            Dropdown {
                width: 130
                showLabel: false
                value: String(root.qualityLimit)
                options: [
                    { value: "720", label: "Up to 720p" },
                    { value: "1080", label: "Up to 1080p" },
                    { value: "1440", label: "Up to 1440p" },
                    { value: "2160", label: "Up to 2160p" },
                    { value: "0", label: "Any quality" }
                ]
                onChanged: function(value) { root.qualityLimitRequested(Number(value)); }
            }
            Dropdown {
                width: 120
                showLabel: false
                value: String(root.sizeLimit)
                options: [
                    { value: "0", label: "Any size" },
                    { value: "1073741824", label: "Up to 1 GB" },
                    { value: "2147483648", label: "Up to 2 GB" },
                    { value: "4294967296", label: "Up to 4 GB" },
                    { value: "8589934592", label: "Up to 8 GB" }
                ]
                onChanged: function(value) { root.sizeLimitRequested(Number(value)); }
            }
            Dropdown {
                width: 125
                showLabel: false
                value: root.sortMode
                options: [
                    { value: "balanced", label: "Balanced" },
                    { value: "sources", label: "Most sources" },
                    { value: "smallest", label: "Smallest first" },
                    { value: "quality", label: "Quality first" }
                ]
                onChanged: function(value) { root.sortModeRequested(value); }
            }
        }

        ListView {
            ScrollBar.vertical: OmaCineScrollBar { uiScale: root.uiScale }
            id: choices
            Layout.fillWidth: true
            Layout.preferredHeight: root.expanded ? contentHeight : 0
            visible: root.expanded
            // No inner scrolling: every stream is laid out and the details
            // column scrolls, so nothing is hidden behind a nested viewport.
            interactive: false
            clip: false
            spacing: 4
            model: root.filteredStreams()
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            flickDeceleration: 900
            maximumFlickVelocity: 6000
            delegate: Button {
                required property var modelData
                width: choices.width
                text: root.streamLabel(modelData.stream) + root.rememberedSuffix(modelData.originalIndex)
                tooltipText: root.streamTooltip(modelData.stream, "Select this stream")
                leftAlign: true
                selected: modelData.originalIndex === root.selectedIndex
                fontSize: root.fs(Style.font.caption)
                onClicked: root.selected(modelData.originalIndex)
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? Math.round(46 * root.uiScale) : 0
            visible: root.expanded && root.filteredStreams().length === 0
            text: "No streams match these limits. Increase the quality or size limit."
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: root.fs(Style.font.caption)
            color: Qt.darker(Color.foreground, 1.35)
        }

    }
}
