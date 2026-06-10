const { app, Tray, Menu, BrowserWindow } = require('electron');
const path = require('path');

let tray = null;
let window = null;

app.whenReady().then(() => {
  // Create the tray icon
  tray = new Tray(path.join(__dirname, 'icon.png')); // We will need an icon.png
  
  const contextMenu = Menu.buildFromTemplate([
    { label: 'AI Usage: 45%', enabled: false },
    { type: 'separator' },
    { label: 'Settings', click: () => {
        if (!window) {
            createWindow();
        } else {
            window.show();
        }
    }},
    { label: 'Quit', click: () => app.quit() }
  ]);
  
  tray.setToolTip('AI Subscription Usage');
  tray.setContextMenu(contextMenu);
});

function createWindow() {
  window = new BrowserWindow({
    width: 400,
    height: 300,
    webPreferences: {
      nodeIntegration: true
    }
  });

  window.loadFile('index.html');
  window.on('closed', () => {
    window = null;
  });
}

// Hide from dock for a pure status bar app
if (app.dock) {
    app.dock.hide();
}

app.on('window-all-closed', () => {
  // Prevent default behavior of quitting when windows close
});
