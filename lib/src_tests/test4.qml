import QtQuick 2.1
import QtQuick.Controls 1.0

ApplicationWindow {
  visible: true;
    Timer {
         interval: 5000;
         running: true;
         repeat: false
         onTriggered: {
             runner.run();
             Qt.quit();
         }
    }
  Component.onCompleted: console.log("test4");
}
