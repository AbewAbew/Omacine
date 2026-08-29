import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Rectangle {
    id: root

    property var item: null
    property real uiScale: 1.0
    // Text scale from Settings > Interface, handed down by the panel.
    property real textScale: 1.0
    // Language is set proportionally; see Panel.qml for why.
    // Set by Panel.qml from the Interface setting, so it must be assignable.
    property string uiFont: "Adwaita Sans"
    function fs(size) {
        var base = Number(size);
        return Math.max(1, Math.round((isNaN(base) ? 10 : base) * root.textScale));
    }
    property var urlResolver: null
    property bool loading: false
    // Rotation state is owned by the panel; the hero only renders it.
    property int slideCount: 0
    property int slideIndex: 0
    readonly property bool hovered: heroHover.hovered
    // How strongly the art is tinted; driven by Settings > Interface.
    property real overlayOpacity: 0.16
    signal activated()
    signal libraryRequested()
    signal slideRequested(int index)

    // Prefer the on-disk copy so a rotation back to this slide is instant.
    readonly property string backdropSource: (root.item && root.urlResolver)
                                           ? root.urlResolver(root.item.backdropPath || root.item.backdrop
                                                              || root.item.coverPath || root.item.cover || "") : ""
    property string previousBackdrop: ""
    property string shownTitle: ""

    radius: Math.round(Style.cornerRadius * 1.4)
    color: Color.popups.background
    clip: true

    // Crossfade: the outgoing art stays on top and dissolves to reveal the
    // incoming art already painted underneath.
    onBackdropSourceChanged: {
        if (root.previousBackdrop && root.previousBackdrop !== root.backdropSource) {
            fadeLayer.source = root.previousBackdrop;
            fadeLayer.opacity = 1.0;
            backdropFade.restart();
        }
        root.previousBackdrop = root.backdropSource;
    }
    // Only re-reveal on a genuine slide change; swapping a remote URL for its
    // freshly cached file must not flash the same text.
    onItemChanged: {
        var title = root.item ? String(root.item.title || "") : "";
        if (title === root.shownTitle) return;
        root.shownTitle = title;
        textReveal.restart();
    }

    Image {
        id: baseLayer
        anchors.fill: parent
        source: root.backdropSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: Math.round(root.width)
        sourceSize.height: Math.round(root.height)
    }

    Image {
        id: fadeLayer
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        opacity: 0
        // Only exists during a crossfade; otherwise it is a second full-size
        // texture composited every frame for nothing.
        visible: opacity > 0
        sourceSize.width: Math.round(root.width)
        sourceSize.height: Math.round(root.height)
    }

    NumberAnimation {
        id: backdropFade
        target: fadeLayer
        property: "opacity"
        from: 1.0
        to: 0.0
        duration: 520
        easing.type: Easing.InOutQuad
    }

    // Barely-there tint: just enough to seat the art in the panel. The text
    // gets its contrast from the gradient below, not from dimming the image.
    Rectangle {
        anchors.fill: parent
        color: Color.popups.background
        opacity: root.overlayOpacity
        Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.min(parent.width * 0.55, Math.round(700 * root.uiScale))
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.94) }
            GradientStop { position: 0.70; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.70) }
            GradientStop { position: 1.0; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.0) }
        }
    }

    ColumnLayout {
        id: heroText
        anchors.left: parent.left
        anchors.leftMargin: Math.round(28 * root.uiScale)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.round(26 * root.uiScale)
        width: Math.min(parent.width * 0.42, Math.round(560 * root.uiScale))
        spacing: Math.round(8 * root.uiScale)

        Text {
            Layout.fillWidth: true
            text: "OMACINE SPOTLIGHT"
            font.family: root.uiFont
            font.pixelSize: root.fs(Style.font.caption - 1)
            font.bold: true
            color: Color.accent
            opacity: 0.95
        }
        Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.loading ? "Loading tonight’s highlights…" : (root.item ? root.item.title || "" : "Discover something worth watching")
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.family: root.uiFont
            font.pixelSize: root.fs(Math.round(28 * root.uiScale))
            font.bold: true
            color: Color.foreground
        }
        Text {
            Layout.fillWidth: true
            visible: root.item !== null
            textFormat: Text.PlainText
            text: {
                if (!root.item) return "";
                var parts = [];
                if (root.item.year) parts.push(root.item.year);
                parts.push(Number(root.item.stype || 1) === 2 ? "TV Series" : "Movie");
                if (Number(root.item.rating || 0) > 0) parts.push("★ " + root.item.rating);
                return parts.join("  •  ");
            }
            font.family: root.uiFont
            font.pixelSize: root.fs(Style.font.caption)
            color: Color.accent
        }
        Text {
            Layout.fillWidth: true
            visible: root.item !== null && String(root.item.overview || "").length > 0
            textFormat: Text.PlainText
            text: root.item ? root.item.overview || "" : ""
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            font.family: root.uiFont
            font.pixelSize: root.fs(Style.font.caption)
            color: Qt.darker(Color.foreground, 1.14)
        }
        RowLayout {
            visible: root.item !== null
            spacing: 8
            Button {
                text: "View details"
                iconText: "\uf04b"
                selected: true
                onClicked: root.activated()
            }
            Button {
                text: "My Library"
                iconText: "\uf02e"
                onClicked: root.libraryRequested()
            }
        }
    }

    SequentialAnimation {
        id: textReveal
        PropertyAction { target: heroText; property: "opacity"; value: 0.0 }
        NumberAnimation { target: heroText; property: "opacity"; to: 1.0; duration: 420; easing.type: Easing.OutCubic }
    }

    // Position markers double as manual slide selection.
    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Math.round(18 * root.uiScale)
        anchors.bottomMargin: Math.round(14 * root.uiScale)
        spacing: Math.round(6 * root.uiScale)
        visible: root.slideCount > 1 && !root.loading

        Repeater {
            model: root.slideCount
            delegate: Rectangle {
                width: index === root.slideIndex ? Math.round(18 * root.uiScale) : Math.round(6 * root.uiScale)
                height: Math.round(6 * root.uiScale)
                radius: height / 2
                color: index === root.slideIndex ? Color.accent : Color.foreground
                opacity: index === root.slideIndex ? 1.0 : 0.38
                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 220 } }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    scrollGestureEnabled: false
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.slideRequested(index)
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: root.loading
        color: Color.popups.background
        opacity: 0.3
        SequentialAnimation on opacity {
            running: root.loading
            loops: Animation.Infinite
            NumberAnimation { from: 0.25; to: 0.48; duration: 650 }
            NumberAnimation { from: 0.48; to: 0.25; duration: 650 }
        }
    }

    // HoverHandler reports hover across the whole hero without swallowing
    // clicks meant for the buttons, so rotation can pause while reading.
    HoverHandler {
        id: heroHover
    }
}
