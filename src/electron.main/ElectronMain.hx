import electron.main.App;
import electron.main.IpcMain;
import js.Node.__dirname;
import js.Node.process;
import js.node.ChildProcess;
import js.node.Net;
import js.node.Http;

class ElectronMain {
	static var mainWindow : electron.main.BrowserWindow;

	static var settings : Settings;

	// GLDtk: the bundled Python backend (packaged app only; dev uses start.sh)
	static var gldtkServer : Null<js.node.child_process.ChildProcess>;
	static inline var GLDTK_DEFAULT_PORT = 8765;

	static function main() {
		// GLDtk: the packaged app keeps its own user data, apart from a real LDtk install
		if( js.node.Fs.existsSync((untyped process.resourcesPath) + "/gldtk-server") )
			App.setPath("userData", App.getPath("appData") + "/GLDtk");

		settings = new Settings();

		// Force best available GPU usage
		if( settings.v.useBestGPU && !App.commandLine.hasSwitch("force_low_power_gpu") )
			App.commandLine.appendSwitch("force_high_performance_gpu");

		App.whenReady().then( (_)->startGldtkServer(showSplashWindow) );
		App.on("will-quit", (_)->stopGldtkServer());
		process.on("exit", (_)->stopGldtkServer());

		// Mac
		App.on('window-all-closed', function() {
			mainWindow = null;
			App.quit();
		});
		App.on('activate', ()->{
			if( electron.main.BrowserWindow.getAllWindows().length == 0 )
				showSplashWindow();
		});

		initIpcBindings();
	}


	static function initIpcBindings() {
		// *** invoke/handle *****************************************************

		IpcMain.handle("appReady", function(ev) {
			// Window close button
			mainWindow.on('close', function(ev) {
				if( !dn.js.ElectronUpdater.isIntalling ) {
					ev.preventDefault();
					mainWindow.webContents.send("onWinClose");
				}
			});
			// Window move
			mainWindow.on('move', function(ev) {
				mainWindow.webContents.send("onWinMove");
			});
		});


		// *** sendSync/on *****************************************************
	}

	/** Starts <resources>/gldtk-server/gldtk-server on port 8765 (or a free port), then calls `next`.
		The port reaches the renderer through the GLDTK_PORT environment variable. **/
	static function startGldtkServer(next:Void->Void) {
		var exe = (untyped process.resourcesPath) + "/gldtk-server/gldtk-server";
		if( !js.node.Fs.existsSync(exe) ) {
			next(); // dev: server.py is started by start.sh
			return;
		}
		function launch(port:Int) {
			process.env.set("GLDTK_PORT", Std.string(port));
			gldtkServer = ChildProcess.spawn(exe, ["--port", Std.string(port), "--parent-pid", Std.string(process.pid)], { stdio:"ignore" });
			gldtkServer.on("error", (_)->{});
			// Wait (up to ~15s) for /health, but never block the UI longer than that
			var tries = 0;
			function poll() {
				var req = Http.get("http://127.0.0.1:"+port+"/health", (res)->{
					res.resume();
					next();
				});
				req.on("error", (_)->{
					if( ++tries >= 60 ) next();
					else haxe.Timer.delay(poll, 250);
				});
			}
			poll();
		}
		// Is the default port free?
		var probe = Net.createServer();
		probe.once("error", (_)->{
			var any = Net.createServer();
			any.listen(0, "127.0.0.1", ()->{
				var port : Int = untyped any.address().port;
				any.close(()->launch(port));
			});
		});
		probe.listen(GLDTK_DEFAULT_PORT, "127.0.0.1", ()->probe.close(()->launch(GLDTK_DEFAULT_PORT)));
	}

	static function stopGldtkServer() {
		if( gldtkServer != null ) {
			try gldtkServer.kill() catch(_) {}
			gldtkServer = null;
		}
	}

	static function fileNotFound(file:String) {
		electron.main.Dialog.showErrorBox("File not found", '"$file" was not found in app assets!');
		App.quit();
	}


	static var splash : electron.main.BrowserWindow = null;
	static function showSplashWindow() {
		#if debug

			createMainWindow();

		#else

			splash = new electron.main.BrowserWindow({
				width: 300,
				height: 300,
				alwaysOnTop: true,
				transparent: true,
				frame: false,
			});

			var ver = new dn.Version( MacroTools.getAppVersion() );

			splash
				.loadFile('assets/splash.html', { query:{
					mainVersion : ver.major+"."+ver.minor,
					patchVersion : ver.patch>0 ? "."+ver.patch : "",
				}})
				.then(
					_->createMainWindow(),
					_->fileNotFound("splash.html")
				);

		#end

	}

	static function createMainWindow() {
		// Init window
		mainWindow = new electron.main.BrowserWindow({
			webPreferences: { nodeIntegration:true, contextIsolation:false },
			fullscreenable: true,
			show: false,
			title: "GLDtk",
			icon: __dirname+"/appIcon.png",
			backgroundColor: '#1e2229'
		});
		mainWindow.once("ready-to-show", ev->{
			mainWindow.webContents.setZoomFactor( settings.getAppZoomFactor() );
			if( settings.v.startFullScreen )
				dn.js.ElectronTools.setFullScreen(true);
			mainWindow.webContents.send("settingsApplied");
		});
		dn.js.ElectronTools.initMain(mainWindow);

		// Window menu
		#if debug
			enableDebugMenu();
		#else
			// electron.main.Menu.setApplicationMenu( electron.main.Menu.buildFromTemplate( [] ) ); // macos
			mainWindow.removeMenu(); // windows
		#end

		// Load app page
		var p = mainWindow.loadFile('assets/app.html');
		#if debug
			// Show immediately
			mainWindow.maximize();
			p.then( (_)->{}, (_)->fileNotFound("app.html") );
		#else
			// Wait for loading before showing up
			p.then( (_)->{
				mainWindow.show();
				mainWindow.maximize();
				splash.destroy();
			}, (_)->{
				splash.destroy();
				fileNotFound("app.html");
			});
		#end

		// Destroy
		mainWindow.on('closed', function() {
			mainWindow = null;
		});

		// Misc bindings
		dn.js.ElectronDialogs.initMain(mainWindow);
		dn.js.ElectronUpdater.initMain(mainWindow);
	}



	// Create a custom debug menu
	#if debug
	static function enableDebugMenu() {
		var menu = electron.main.Menu.buildFromTemplate([{
			label: "Debug tools",
			submenu: cast [
				{
					label: "Reload",
					click: function() mainWindow.reload(),
					accelerator: "CmdOrCtrl+R",
				},
				{
					label: "Dev tools",
					click: function() mainWindow.webContents.toggleDevTools(),
					accelerator: "CmdOrCtrl+Shift+I",
				},
			]
		}]);

		mainWindow.setMenu(menu);
	}
	#end
}
