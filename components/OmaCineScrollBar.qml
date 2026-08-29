import QtQuick
import QtQuick.Controls
import qs.Commons

// Shared scrollbar so every scrollable surface in OmaCine looks the same.
// Deliberately thin and self-hiding: it should tell you where you are without
// competing with the artwork, then fade out when you stop.
ScrollBar {
    id: control

    property real uiScale: 1.0
    // Vertical bars grow along x, horizontal along y; one thickness drives both.
    readonly property int thickness: Math.round(5 * uiScale)

    policy: ScrollBar.AsNeeded
    minimumSize: 0.08
    padding: Math.round(2 * uiScale)

    contentItem: Rectangle {
        implicitWidth: control.thickness
        implicitHeight: control.thickness
        radius: Math.min(width, height) / 2
        color: control.pressed ? Color.accent
             : control.hovered ? Qt.lighter(Color.accent, 1.15)
             : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.38)
        // `active` covers both flicking and hovering the bar itself.
        opacity: control.active ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Behavior on color { ColorAnimation { duration: 140 } }
    }

    background: Rectangle {
        implicitWidth: control.thickness
        implicitHeight: control.thickness
        radius: Math.min(width, height) / 2
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.07)
        opacity: control.active ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 180 } }
    }
}
