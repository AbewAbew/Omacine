import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

Item {
    id: root

    property string title: ""
    property string subtitle: ""
    property var mediaModel: null
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
    property bool showProgress: false
    // Continue Watching needs a way to drop a title; other rails do not.
    property bool removable: false
    signal activated(var item)
    signal previewRequested(var item)
    signal removeRequested(var item)

    // ListModel.get() returns a live reference into the model. Handlers that
    // rebuild or clear the model would see these fields vanish mid-use, so
    // callers always receive a detached copy.
    function itemAt(index) {
        if (!root.mediaModel || !root.mediaModel.get) return null;
        var live = root.mediaModel.get(index);
        if (!live) return null;
        var copy = {};
        for (var key in live) copy[key] = live[key];
        return copy;
    }

    // Grow with the text scale so larger type is not cut off.
    readonly property real textRoom: Math.max(1, textScale)
    implicitHeight: Math.round(236 * uiScale + (textRoom - 1) * 26)

    ColumnLayout {
        anchors.fill: parent
        spacing: Math.round(7 * root.uiScale)

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: root.title
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.body)
                font.bold: true
                color: Color.foreground
            }
            Text {
                Layout.fillWidth: true
                text: root.subtitle
                elide: Text.ElideRight
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.caption - 1)
                color: Qt.darker(Color.foreground, 1.4)
            }
        }

        ListView {
            id: rail
            ScrollBar.horizontal: OmaCineScrollBar { uiScale: root.uiScale }
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: ListView.Horizontal
            spacing: Math.round(10 * root.uiScale)
            clip: true
            model: root.mediaModel
            cacheBuffer: 240
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            flickDeceleration: 900
            maximumFlickVelocity: 6000

            // Same release-inertia fix as the vertical surfaces, on the X axis.
            // Qt tracks the gesture one-for-one but never starts the flick, so
            // the velocity is measured here and handed to native physics.
            // Vertical deltas are ignored so the page still scrolls through.
            property real touchpadVelocityX: 0
            property double touchpadLastMs: 0
            property bool touchpadTracking: false
            property real pendingTouchpadVelocityX: 0

            Timer {
                id: railTouchpadFlickLaunch
                interval: 0
                repeat: false
                onTriggered: {
                    const velocity = rail.pendingTouchpadVelocityX
                    const maximumX = Math.max(0, rail.contentWidth - rail.width)
                    const canContinue = (velocity < 0 && rail.contentX < maximumX)
                                        || (velocity > 0 && rail.contentX > 0)
                    rail.pendingTouchpadVelocityX = 0
                    if (canContinue)
                        rail.flick(velocity, 0)
                }
            }

            WheelHandler {
                target: null
                blocking: false
                orientation: Qt.Horizontal
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(event) {
                    const now = Date.now()
                    const pixelX = event.pixelDelta.x

                    if (pixelX !== 0) {
                        const elapsed = now - rail.touchpadLastMs
                        const instantaneousVelocity = elapsed > 0 ? pixelX * 1000 / elapsed : 0
                        const stale = !rail.touchpadTracking || elapsed > 80
                        const reversed = rail.touchpadVelocityX !== 0
                                && instantaneousVelocity * rail.touchpadVelocityX < 0

                        if (instantaneousVelocity !== 0) {
                            if (stale || reversed)
                                rail.touchpadVelocityX = instantaneousVelocity
                            else
                                rail.touchpadVelocityX = rail.touchpadVelocityX * 0.65
                                        + instantaneousVelocity * 0.35
                        }
                        rail.touchpadLastMs = now
                        rail.touchpadTracking = true
                    }

                    if (event.phase === Qt.ScrollEnd && rail.touchpadTracking) {
                        const releaseAge = now - rail.touchpadLastMs
                        let velocity = releaseAge <= 100 ? rail.touchpadVelocityX * 1.25 : 0
                        velocity = Math.max(-rail.maximumFlickVelocity,
                                            Math.min(rail.maximumFlickVelocity, velocity))
                        rail.pendingTouchpadVelocityX = Math.abs(velocity) >= 180 ? velocity : 0
                        rail.touchpadVelocityX = 0
                        rail.touchpadLastMs = 0
                        rail.touchpadTracking = false
                        if (rail.pendingTouchpadVelocityX !== 0)
                            railTouchpadFlickLaunch.restart()
                    }
                }
            }

            reuseItems: true

            delegate: Item {
                id: card
                width: Math.round((root.showProgress ? 250 : 138) * root.uiScale)
                height: rail.height
                property bool hovered: cardMouse.containsMouse

                Rectangle {
                    anchors.fill: parent
                    anchors.bottomMargin: Math.round(34 * root.uiScale * root.textRoom)
                    radius: Style.cornerRadius
                    color: Color.surface ?? Qt.darker(Color.foreground, 2.2)
                    border.width: card.hovered ? 2 : 0
                    border.color: Color.accent
                    clip: true
                    scale: card.hovered ? 1.025 : 1.0
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    Image {
                        anchors.fill: parent
                        source: root.urlResolver ? root.urlResolver(model.coverPath || model.cover || "") : (model.coverPath || model.cover || "")
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        // Decode at the size actually drawn. Without this every
                        // w342 poster is decoded at 342x513 to be painted at
                        // ~138x174, which is what makes scrolling stutter.
                        sourceSize.width: Math.round(parent.width)
                        sourceSize.height: Math.round(parent.height)
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.round(30 * root.uiScale)
                        color: Qt.rgba(0, 0, 0, 0.64)
                        Text {
                            anchors.centerIn: parent
                            text: Number(model.rating || 0) > 0 ? "★ " + model.rating : (Number(model.stype || 1) === 2 ? "TV" : "MOVIE")
                            font.family: root.uiFont
                            font.pixelSize: root.fs(Style.font.caption - 1)
                            font.bold: true
                            color: "white"
                        }
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 4
                        visible: root.showProgress && Number(model.progress || 0) > 0
                        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(1, Number(model.progress || 0)))
                            height: parent.height
                            color: Color.accent
                        }
                    }
                }
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Math.round(28 * root.uiScale * root.textRoom)
                    textFormat: Text.PlainText
                    text: {
                        var suffix = root.showProgress && Number(model.resumeEpisode || 0) > 0
                                   ? "  •  S" + model.resumeSeason + "E" + model.resumeEpisode : "";
                        return model.title + suffix;
                    }
                    elide: Text.ElideRight
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: card.hovered
                    color: card.hovered ? Color.accent : Color.foreground
                    verticalAlignment: Text.AlignVCenter
                }
                MouseArea {
                    id: cardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    // Poster clicks must not consume two-finger scrolling;
                    // the nested Flickables need the full gesture stream for
                    // axis selection and velocity-based kinetic movement.
                    scrollGestureEnabled: false
                    cursorShape: Qt.PointingHandCursor
                    onEntered: previewTimer.restart()
                    onExited: previewTimer.stop()
                    onClicked: { var picked = root.itemAt(index); if (picked) root.activated(picked); }
                    Timer {
                        id: previewTimer
                        interval: 360
                        repeat: false
                        onTriggered: { var picked = root.itemAt(index); if (picked) root.previewRequested(picked); }
                    }
                }

                // Sits above the card MouseArea so the click removes rather
                // than opens. Fades in on hover to keep the rail uncluttered.
                Rectangle {
                    id: removeButton
                    visible: root.removable
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: Math.round(6 * root.uiScale)
                    anchors.rightMargin: Math.round(6 * root.uiScale)
                    width: Math.round(20 * root.uiScale)
                    height: width
                    radius: width / 2
                    color: removeMouse.containsMouse ? Color.urgent : Qt.rgba(0, 0, 0, 0.66)
                    border.width: 1
                    border.color: removeMouse.containsMouse ? Color.urgent
                                                            : Qt.rgba(1, 1, 1, 0.35)
                    opacity: card.hovered || removeMouse.containsMouse ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    Behavior on color { ColorAnimation { duration: 140 } }

                    Text {
                        anchors.centerIn: parent
                        text: "\u2715"
                        font.family: root.uiFont
                        font.pixelSize: root.fs(Math.round(10 * root.uiScale))
                        font.bold: true
                        color: "white"
                    }

                    MouseArea {
                        id: removeMouse
                        anchors.fill: parent
                        anchors.margins: -3
                        hoverEnabled: true
                        scrollGestureEnabled: false
                        enabled: removeButton.opacity > 0
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { var picked = root.itemAt(index); if (picked) root.removeRequested(picked); }
                    }
                }
            }
        }
    }
}
