import QtQuick
import QtQuick.Layouts
import qs.Commons

// One rating tile: provider mark, the score large, and what the score is.
// Logos are pre-rasterized PNGs — Qt only speaks SVG Tiny, so shipping SVG
// risked a mark silently rendering blank.
Item {
    id: root

    property string logo: ""          // file name in components/logos
    property string label: ""         // fallback text if the mark cannot load
    property string caption: ""       // what the number means
    property string value: ""
    property color background: "transparent"
    property color textColor: Color.foreground
    property real uiScale: 1.0
    property real textScale: 1.0
    // Language is set proportionally; see Panel.qml for why.
    // Set by Panel.qml from the Interface setting, so it must be assignable.
    property string uiFont: "Adwaita Sans"

    function fs(size) {
        var base = Number(size);
        return Math.max(1, Math.round((isNaN(base) ? 10 : base) * root.textScale));
    }

    // Text scale must not drive the tile geometry one-for-one. At 1.6 that made
    // each tile 154px and pushed everything below the ratings off the page, so
    // the box grows at a fraction of the rate the type does.
    readonly property real boxScale: 1 + (Math.max(1, textScale) - 1) * 0.35

    visible: root.value !== ""
    implicitHeight: Math.round(70 * uiScale * boxScale)

    Rectangle {
        anchors.fill: parent
        radius: Math.round(6 * root.uiScale)
        color: root.background

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Math.round(6 * root.uiScale)
            spacing: Math.round(1 * root.uiScale)

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(16 * root.uiScale * root.boxScale)
                Image {
                    id: mark
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: parent.height
                    width: implicitWidth > 0 && implicitHeight > 0
                           ? height * (implicitWidth / implicitHeight) : height
                    source: root.logo ? Qt.resolvedUrl("logos/" + root.logo) : ""
                    visible: root.logo !== "" && status === Image.Ready && implicitWidth > 0
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                    asynchronous: true
                }
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !mark.visible
                    text: root.label
                    font.family: root.uiFont
                    font.pixelSize: root.fs(Style.font.caption)
                    font.bold: true
                    color: root.textColor
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.fillHeight: true
                text: root.value
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.family: Style.font.family
                font.pixelSize: root.fs(20)
                font.bold: true
                fontSizeMode: Text.Fit
                minimumPixelSize: root.fs(12)
                color: root.textColor
            }

            Text {
                Layout.fillWidth: true
                text: root.caption
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                font.family: root.uiFont
                font.pixelSize: root.fs(Style.font.caption - 1)
                color: root.textColor
                opacity: 0.75
            }
        }
    }
}
