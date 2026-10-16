package ui.gldtk;

import ui.gldtk.GldtkPlayPhysics;

class PlayEntity {
	public var kind : String;         // catalog kind (Start, Exit, Enemy, Pickup…)
	public var sub : String = "";     // archetype / pickup kind, lower case
	public var iid : String;
	public var x0 : Float;            // initial box (level px)
	public var y0 : Float;
	public var x : Float;             // current box
	public var y : Float;
	public var w : Float;
	public var h : Float;
	public var color : Int;
	public var tile : Null<ldtk.Json.TilesetRect>;
	public var value = 1;
	public var requiresKey = false;
	public var opens : Null<String>;
	public var patrolPx = 0.;
	public var dir = 1.;
	public var t = 0.;
	public var done = false;          // picked up

	public function new() {}

	public function reset() {
		x = x0;
		y = y0;
		dir = 1;
		t = 0;
		done = false;
	}

	public inline function overlaps(l:Float, t:Float, r:Float, b:Float) : Bool {
		return l < x + w && r > x && t < y + h && b > y;
	}
}

/**
	GLDtk play mode (v3 Part 16): plays the open level in a modal, with the
	Game Profile's physics (`GET /profile`) and the sections' gravity
	(`gldtk_sections`), on a plain canvas with its own requestAnimationFrame
	loop and a fixed 60 Hz tick. The motion model is in `GldtkPlayPhysics`.

	The level is read from the project in memory and never written: nothing
	in the project changes, so it is not marked as modified. While the modal is
	open every key goes to the game (a capturing listener on the window stops
	them before LDtk and Heaps see them), so keystrokes cannot edit the level.

	Rules: pickups are counted (coins, gems, health adds a life); hazard tiles,
	enemies and falling out of the level cost a life and respawn at the last
	checkpoint (or the Start); enemies patrol their `patrol_range`, flyers bob;
	an Exit with `requires_key` opens once a Key is collected; reaching the Exit
	shows the time and pickups.
**/
class GldtkPlay {
	static var SERVER = "http://127.0.0.1:" + (js.Node.process.env.exists("GLDTK_PORT") ? js.Node.process.env.get("GLDTK_PORT") : "8765"); // set by the main process in the packaged app
	static inline var GHOST_KEY = "gldtk_play_ghost";
	static inline var LIVES = 3;
	static inline var INVULNERABLE_S = 1.0;
	static inline var HAZARD_INSET = 2.0;  // px of the hitbox that may brush a hazard
	static inline var ENEMY_SPEED = 40.0;
	static inline var VIEW_TILES_Y = 14;   // tiles shown vertically (fewer when the level is smaller)
	static inline var VIEW_TILES_X = 24;

	public static var current(default,null) : Null<GldtkPlay>;

	var jRoot : J;
	var jStage : J;
	var jEnd : J;
	var jNote : J;
	var jGhost : J;
	var canvas : js.html.CanvasElement;
	var ctx : js.html.CanvasRenderingContext2D;

	var project : data.Project;
	var level : data.Level;
	var path : String;
	var prof : Null<PlayProfile>;
	var grid : PlayGrid;
	var player : Null<PlayPlayer>;
	var entities : Array<PlayEntity> = [];
	var levelCanvas : js.html.CanvasElement;
	var images : Map<Int, js.html.Image> = new Map();
	var route : Null<Dynamic>;
	var stuck : Array<{col:Int, row:Int, w:Int}> = []; // soft-lock spans (cells), v4 Part 29b
	var wasStuck = false;

	// Input
	var held : Map<String,Bool> = new Map();
	var prevKeys : PlayKeys = { left: false, right: false, jump: false, dash: false };
	var forcedKeys : Null<PlayKeys>; // debug hook
	var onKeyDownFn : js.html.KeyboardEvent->Void;
	var onKeyUpFn : js.html.KeyboardEvent->Void;
	var onBlurFn : js.html.Event->Void;

	// Loop
	var raf = -1;
	var lastT = -1.;
	var acc = 0.;
	var debugPaused = false;
	var camX = 0.;
	var camY = 0.;
	var camReady = false;

	// Game state
	var spawnX = 0.;
	var spawnY = 0.;
	var checkX = 0.;
	var checkY = 0.;
	var lives = LIVES;
	var coins = 0;
	var gems = 0;
	var keys : Array<String> = [];
	var deaths = 0;
	var time = 0.;
	var ticks = 0;
	var invulnerable = 0.;
	var won = false;
	var over = false;
	var toast = "";
	var toastT = 0.;
	var totalCoins = 0;
	var totalGems = 0;

	/** Opens play mode for *level* of *project* (already saved to *path*). **/
	public static function open(project:data.Project, level:data.Level, path:String) {
		if( current != null ) current.close();
		current = new GldtkPlay(project, level, path);
		#if debug installDebugHook(); #end
	}

	function new(project:data.Project, level:data.Level, path:String) {
		this.project = project;
		this.level = level;
		this.path = path;
		buildDom();
		readLevel();
		listen();
		fetchProfile();
		fetchRoute();
		raf = js.Browser.window.requestAnimationFrame(frame);
	}

	// ── DOM ───────────────────────────────────────────────────────────────

	function buildDom() {
		var active = js.Browser.document.activeElement;
		if( active != null ) active.blur(); // a focused sidebar field must not see the keys

		jRoot = new J('<div id="gldtk-play" tabindex="-1"></div>');
		jRoot.html('
			<div class="gp-panel">
				<div class="gp-head">
					<span class="gp-title">&#x25B6; Play</span>
					<span class="gp-level"></span>
					<span class="gp-prof"></span>
					<label class="gp-ghost" title="Show the golden route as a faint line (G)"><input type="checkbox"/>Route ghost</label>
					<button class="gp-close gray" title="Close (Esc)">Close</button>
				</div>
				<div class="gp-stage">
					<canvas></canvas>
					<div class="gp-end"></div>
					<div class="gp-note"></div>
				</div>
				<div class="gp-help"></div>
			</div>
		');
		new J("body").append(jRoot);
		jStage = jRoot.find(".gp-stage");
		jEnd   = jRoot.find(".gp-end");
		jNote  = jRoot.find(".gp-note");
		jGhost = jRoot.find(".gp-ghost input");
		jRoot.find(".gp-level").text(level.identifier);
		canvas = cast jRoot.find("canvas").get(0);
		ctx = canvas.getContext2d();

		jGhost.prop("checked", loadStr(GHOST_KEY) == "1");
		jGhost.change( _-> setGhost(jGhost.prop("checked") == true) );
		jRoot.find(".gp-close").click( _-> close() );
		// The editor must not get the mouse either (wheel zoom, tools)
		jRoot.on("mousedown mouseup wheel contextmenu", (ev:js.jquery.Event)-> ev.stopPropagation());
		jRoot.get(0).focus();
		note("Loading the Game Profile…");
	}

	function note(s:String) {
		jNote.text(s);
		jNote.toggle(s.length > 0);
	}

	function setGhost(on:Bool) {
		jGhost.prop("checked", on);
		saveStr(GHOST_KEY, on ? "1" : "0");
	}

	static function saveStr(k:String, v:String) try js.Browser.window.localStorage.setItem(k, v) catch(_) {}
	static function loadStr(k:String) : Null<String> {
		try return js.Browser.window.localStorage.getItem(k) catch(_) return null;
	}

	static function esc(s:Dynamic) : String {
		return s == null ? "" : StringTools.htmlEscape(Std.string(s), true);
	}

	// ── Server ────────────────────────────────────────────────────────────

	function get(route:String, onDone:(status:Int, res:Dynamic)->Void, onOffline:Void->Void) {
		var xhr = new js.html.XMLHttpRequest();
		xhr.open("GET", SERVER + route);
		xhr.onload = function(_) {
			var res : Dynamic = null;
			try { res = haxe.Json.parse(xhr.responseText); } catch(_) {}
			onDone(xhr.status, res);
		};
		xhr.onerror = function(_) onOffline();
		xhr.send();
	}

	function fetchProfile() {
		get("/profile?path=" + StringTools.urlEncode(path), (status, res)-> {
			if( current != this ) return;
			if( status == 200 && res != null )
				start( PlayProfile.fromJson(res), "" );
			else
				start( new PlayProfile(), "The Game Profile could not be read, so the default physics are used." );
		}, ()-> {
			if( current == this )
				start( new PlayProfile(), "GLDtk server offline: playing with the default Game Profile." );
		});
	}

	function fetchRoute() {
		get("/route?path=" + StringTools.urlEncode(path), (status, res)-> {
			if( current != this || status != 200 || res == null || res.success != true ) return;
			if( res.level_iid != null && res.level_iid != level.iid ) return;
			route = res;
			stuck = [];
			var spans : Array<Dynamic> = res.softlock_spans != null ? res.softlock_spans : [];
			for( sp in spans ) stuck.push({ col:Std.int(sp.col), row:Std.int(sp.row), w:Std.int(sp.w) });
		}, ()->{} );
	}

	// ── Level ─────────────────────────────────────────────────────────────

	function gridLayer() : Null<data.inst.LayerInstance> {
		for( li in level.layerInstances )
			if( li.def.type == IntGrid )
				return li;
		return null;
	}

	static function field(ei:data.inst.EntityInstance, id:String) : Null<data.inst.FieldInstance> {
		for( fi in ei.fieldInstances )
			if( fi.def.identifier == id )
				return fi;
		return null;
	}

	function readLevel() {
		var li = gridLayer();
		var gs = li != null ? li.def.gridSize : 16;
		grid = new PlayGrid(li != null ? li.cWid : Std.int(Math.ceil(level.pxWid / gs)), li != null ? li.cHei : Std.int(Math.ceil(level.pxHei / gs)), gs);
		if( li != null ) {
			var hazard = 2;
			for( iv in li.def.getAllIntGridValues() )
				if( iv.identifier != null && iv.identifier.toLowerCase() == "hazard" )
					hazard = iv.value;
			for( cy in 0...li.cHei )
				for( cx in 0...li.cWid ) {
					var v = li.getIntGrid(cx, cy);
					if( v != 0 )
						grid.set(cx, cy, v == hazard ? PlayGrid.HAZARD : PlayGrid.SOLID);
				}
		}

		// Sections (gravity per band)
		for( fi in level.fieldInstances )
			if( fi.def.identifier == "gldtk_sections" && !fi.valueIsNull(0) ) {
				try {
					var arr : Array<Dynamic> = haxe.Json.parse( fi.getString(0) );
					if( Std.isOfType(arr, Array) ) grid.setSections(arr);
				}
				catch(_) {}
			}

		// Entities
		entities = [];
		for( eli in level.layerInstances ) {
			if( eli.def.type != Entities ) continue;
			for( ei in eli.entityInstances ) {
				var e = new PlayEntity();
				e.kind = ei.def.identifier;
				e.iid = ei.iid;
				e.w = ei.width;
				e.h = ei.height;
				e.x0 = eli.pxTotalOffsetX + ei.x - ei.def.pivotX * ei.width;
				e.y0 = eli.pxTotalOffsetY + ei.y - ei.def.pivotY * ei.height;
				e.color = ei.def.color;
				e.tile = ei.getSmartTile();
				for( id in ["archetype", "pickup_kind"] ) {
					var fi = field(ei, id);
					if( fi != null && !fi.valueIsNull(0) ) {
						var v = fi.getEnumValue(0);
						if( v != null ) e.sub = v.toLowerCase();
					}
				}
				var fi = field(ei, "value");
				if( fi != null && fi.getInt(0) != null ) e.value = fi.getInt(0);
				fi = field(ei, "requires_key");
				if( fi != null ) e.requiresKey = fi.getBool(0);
				fi = field(ei, "opens");
				if( fi != null && !fi.valueIsNull(0) ) e.opens = fi.getEntityRefIid(0);
				fi = field(ei, "patrol_range");
				if( fi != null && fi.getInt(0) != null ) e.patrolPx = fi.getInt(0) * grid.ts;
				e.reset();
				entities.push(e);
			}
		}
		totalCoins = totalGems = 0;
		for( e in entities )
			if( e.kind == "Pickup" )
				switch e.sub {
					case "coin": totalCoins += e.value;
					case "gem": totalGems += e.value;
					case _:
				}

		// Spawn: the Start's bottom centre, else the first place to stand
		var start = entities.filter( e->e.kind == "Start" )[0];
		if( start != null ) {
			spawnX = start.x0 + start.w / 2;
			spawnY = start.y0 + start.h;
		}
		else {
			spawnX = grid.ts / 2;
			spawnY = 0;
			for( cy in 1...grid.hei )
				if( grid.get(0, cy) == PlayGrid.SOLID && grid.get(0, cy-1) == PlayGrid.EMPTY ) {
					spawnY = cy * grid.ts;
					break;
				}
		}
		drawLevelCanvas();
	}

	function imageFor(tilesetUid:Null<Int>) : Null<js.html.Image> {
		if( tilesetUid == null ) return null;
		if( images.exists(tilesetUid) ) return images.get(tilesetUid);
		var td = project.defs.getTilesetDef(tilesetUid);
		if( td == null || !td.isAtlasLoaded() ) {
			images.set(tilesetUid, null);
			return null;
		}
		var img = td.createAtlasHtmlImage();
		images.set(tilesetUid, img);
		if( !img.complete )
			img.onload = ()-> if( current == this ) drawLevelCanvas();
		return img;
	}

	static inline function ready(img:Null<js.html.Image>) return img != null && img.complete && img.naturalWidth > 0;

	static function css(c:Int, alpha=1.0) : String {
		return 'rgba(${(c >> 16) & 0xff},${(c >> 8) & 0xff},${c & 0xff},$alpha)';
	}

	/** The static level (background, IntGrid, tiles) drawn once at 1 px per level px. **/
	function drawLevelCanvas() {
		if( levelCanvas == null ) levelCanvas = cast js.Browser.document.createCanvasElement();
		levelCanvas.width = level.pxWid;
		levelCanvas.height = level.pxHei;
		var c = levelCanvas.getContext2d();
		c.imageSmoothingEnabled = false;
		c.fillStyle = css(level.getBgColor());
		c.fillRect(0, 0, level.pxWid, level.pxHei);

		// Cells covered by a tile: their IntGrid colour stays hidden
		var ts = grid.ts;
		var covered = new Map<Int,Bool>();
		for( li in level.layerInstances ) {
			if( !li.visible || li.def.type != Tiles ) continue;
			if( !ready(imageFor(li.getTilesetUid())) ) continue;
			var gs = li.def.gridSize;
			for( cy in 0...li.cHei )
				for( cx in 0...li.cWid )
					if( li.hasAnyGridTile(cx, cy) ) {
						var gx = Std.int((li.pxTotalOffsetX + cx*gs) / ts), gy = Std.int((li.pxTotalOffsetY + cy*gs) / ts);
						covered.set(gx + gy * grid.wid, true);
					}
		}

		var i = level.layerInstances.length - 1;
		while( i >= 0 ) {
			var li = level.layerInstances[i--];
			if( !li.visible ) continue;
			switch li.def.type {
				case IntGrid:
					if( li != gridLayer() ) continue;
					for( cy in 0...grid.hei )
						for( cx in 0...grid.wid ) {
							var v = grid.get(cx, cy);
							if( v == PlayGrid.EMPTY || covered.exists(cx + cy * grid.wid) ) continue;
							var col = li.getIntGridColorAt(cx, cy);
							drawCell(c, cx * ts, cy * ts, ts, v, col != null ? col : (v == PlayGrid.HAZARD ? 0xd2364b : 0x5a6275));
						}

				case Tiles:
					var td = li.getTilesetDef();
					var img = td != null ? imageFor(td.uid) : null;
					if( !ready(img) ) continue;
					c.globalAlpha = li.def.displayOpacity;
					var gs = li.def.gridSize, tg = td.tileGridSize;
					for( cy in 0...li.cHei )
						for( cx in 0...li.cWid )
							for( t in li.getGridTileStack(cx, cy) )
								drawImage(c, img, td.getTileSourceX(t.tileId), td.getTileSourceY(t.tileId), tg, tg,
									li.pxTotalOffsetX + cx*gs, li.pxTotalOffsetY + cy*gs, gs, gs, t.flips);
					c.globalAlpha = 1;

				case _:
			}
		}
	}

	/** Flat colour cell; hazards get spikes so they read as dangerous without tiles. **/
	static function drawCell(c:js.html.CanvasRenderingContext2D, x:Float, y:Float, ts:Float, v:Int, col:Int) {
		if( v == PlayGrid.HAZARD ) {
			c.fillStyle = css(col, 0.35);
			c.fillRect(x, y, ts, ts);
			c.fillStyle = css(col);
			c.beginPath();
			for( k in 0...3 ) {
				var sx = x + k * ts / 3;
				c.moveTo(sx, y + ts);
				c.lineTo(sx + ts / 6, y + ts * 0.3);
				c.lineTo(sx + ts / 3, y + ts);
			}
			c.fill();
		}
		else {
			c.fillStyle = css(col);
			c.fillRect(x, y, ts, ts);
			c.fillStyle = "rgba(255,255,255,0.12)";
			c.fillRect(x, y, ts, 2);
		}
	}

	static function drawImage(c:js.html.CanvasRenderingContext2D, img:js.html.Image, sx:Float, sy:Float, sw:Float, sh:Float,
	                          dx:Float, dy:Float, dw:Float, dh:Float, flips=0) {
		if( flips == 0 ) {
			c.drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh);
			return;
		}
		var fx = flips & 1 != 0, fy = flips & 2 != 0;
		c.save();
		c.translate(dx + (fx ? dw : 0), dy + (fy ? dh : 0));
		c.scale(fx ? -1 : 1, fy ? -1 : 1);
		c.drawImage(img, sx, sy, sw, sh, 0, 0, dw, dh);
		c.restore();
	}

	// ── Game ──────────────────────────────────────────────────────────────

	function start(p:PlayProfile, warning:String) {
		prof = p;
		player = new PlayPlayer(p, grid);
		var abilities = [];
		if( p.doubleJump ) abilities.push("double jump");
		if( p.dash ) abilities.push(p.dashAir ? "dash" : "ground dash");
		if( p.wallJump ) abilities.push("wall jump");
		jRoot.find(".gp-prof").text('${p.name} · g ${p.gravity} · jump ${p.jumpV} · run ${p.runSpeed}' +
			(abilities.length > 0 ? ' · ${abilities.join(", ")}' : ""));
		var help = ["&#x2190;/&#x2192; or A/D run", "Space, W or &#x2191; jump (hold for height)"];
		if( p.doubleJump ) help.push("jump again in the air: double jump");
		if( p.wallJump ) help.push("jump beside a wall: wall jump");
		if( p.dash ) help.push("Shift dash");
		help = help.concat(["R restart", "G route ghost", "Esc close"]);
		jRoot.find(".gp-help").html(help.join(" &middot; "));
		note(warning);
		if( warning.length > 0 )
			haxe.Timer.delay( ()-> if( current == this && jNote.text() == warning ) note(""), 5000 );
		restart();
	}

	function restart() {
		if( player == null ) return;
		for( e in entities ) e.reset();
		lives = LIVES;
		coins = gems = deaths = ticks = 0;
		keys = [];
		time = 0;
		invulnerable = 0;
		won = over = false;
		toast = "";
		checkX = spawnX;
		checkY = spawnY;
		player.reset(spawnX, spawnY);
		prevKeys = currentKeys(); // a key still held from before is not a new press
		camReady = false;
		jEnd.removeClass("on").empty();
	}

	inline function isHeld(codes:Array<String>) : Bool {
		var any = false;
		for( c in codes ) if( held.get(c) == true ) any = true;
		return any;
	}

	function currentKeys() : PlayKeys {
		if( forcedKeys != null ) return forcedKeys;
		return {
			left:  isHeld(["ArrowLeft", "KeyA"]),
			right: isHeld(["ArrowRight", "KeyD"]),
			jump:  isHeld(["Space", "KeyW", "ArrowUp"]),
			dash:  isHeld(["ShiftLeft", "ShiftRight"]),
		};
	}

	/** One fixed 1/60 s tick of the game. **/
	function tick() {
		if( player == null || won || over ) return;
		var k = currentKeys();
		player.step(k, prevKeys);
		prevKeys = k;
		time += PlayPlayer.DT;
		ticks++;
		if( invulnerable > 0 ) invulnerable -= PlayPlayer.DT;
		if( toastT > 0 ) toastT -= PlayPlayer.DT;
		for( e in entities )
			if( e.kind == "Enemy" ) moveEnemy(e);

		var p = player, pr = prof;
		var l = p.x - p.hw, r = p.x + p.hw, t = p.y - pr.height, b = p.y;
		for( e in entities ) {
			if( e.done || !e.overlaps(l, t, r, b) ) continue;
			switch e.kind {
				case "Pickup":
					e.done = true;
					switch e.sub {
						case "coin": coins += e.value;
						case "gem": gems += e.value;
						case "health": lives += M.imax(1, e.value); say("+1 life");
						case _: say(e.sub.length > 0 ? e.sub : "pickup");
					}
				case "Key":
					e.done = true;
					keys.push(e.iid);
					say("Key collected");
				case "Checkpoint":
					var cx = e.x0 + e.w / 2, cy = e.y0 + e.h;
					if( cx != checkX || cy != checkY ) {
						checkX = cx;
						checkY = cy;
						say("Checkpoint");
					}
				case "Enemy":
					if( invulnerable <= 0 ) {
						die();
						return;
					}
				case "Exit":
					if( exitOpen(e) ) {
						win();
						return;
					}
					if( toastT <= 0 ) say("Locked: find the key");
				case _:
			}
		}
		var inStuck = inStuckSpan();
		if( inStuck && !wasStuck ) say("You are in a spot with no way to the Exit");
		wasStuck = inStuck;
		if( p.touches(PlayGrid.HAZARD, HAZARD_INSET) || p.y - pr.height > grid.hei * grid.ts )
			die();
	}

	function exitOpen(exit:PlayEntity) : Bool {
		if( !exit.requiresKey ) return true;
		var dedicated = entities.filter( e->e.kind == "Key" && e.opens == exit.iid );
		if( dedicated.length > 0 )
			return dedicated.filter( k->keys.contains(k.iid) ).length > 0;
		return keys.length > 0;
	}

	function say(s:String) {
		toast = s;
		toastT = 1.5;
	}

	function moveEnemy(e:PlayEntity) {
		var dt = PlayPlayer.DT;
		e.t += dt;
		if( e.sub == "turret" ) return;
		var speed = e.sub == "boss" ? ENEMY_SPEED * 0.75 : ENEMY_SPEED;
		if( e.patrolPx > 0 ) {
			var nx = e.x + e.dir * speed * dt;
			var turn = Math.abs(nx - e.x0) > e.patrolPx;
			if( !turn && e.sub != "flyer" ) {
				// Walkers stay on their floor and turn at walls
				var ts = grid.ts;
				var front = e.dir > 0 ? nx + e.w : nx;
				var col = Std.int(Math.floor((e.dir > 0 ? front - 0.01 : front) / ts));
				var below = Std.int(Math.floor((e.y0 + e.h + 1) / ts));
				var mid = Std.int(Math.floor((e.y0 + e.h / 2) / ts));
				turn = grid.get(col, mid) == PlayGrid.SOLID || grid.get(col, below) != PlayGrid.SOLID;
			}
			if( turn ) e.dir = -e.dir;
			else e.x = nx;
		}
		switch e.sub {
			case "flyer": e.y = e.y0 + Math.sin(e.t * Math.PI) * 6;
			case "jumper": e.y = e.y0 - Math.abs(Math.sin(e.t * Math.PI * 0.8)) * 10;
			case _:
		}
	}

	function die() {
		deaths++;
		lives--;
		if( lives <= 0 ) {
			over = true;
			showEnd(false);
			return;
		}
		player.reset(checkX, checkY);
		invulnerable = INVULNERABLE_S;
		say(lives == 1 ? "Ouch! 1 life left" : 'Ouch! $lives lives left');
	}

	function win() {
		won = true;
		showEnd(true);
	}

	static function fmtTime(t:Float) : String {
		var s = Std.int(t);
		return '${Std.int(s / 60)}:${StringTools.lpad(Std.string(s % 60), "0", 2)}.${Std.int((t - s) * 10)}';
	}

	function showEnd(complete:Bool) {
		var stats = [ 'Time <b>${fmtTime(time)}</b>' ];
		if( totalCoins > 0 ) stats.push('Coins <b>$coins / $totalCoins</b>');
		if( totalGems > 0 ) stats.push('Gems <b>$gems / $totalGems</b>');
		stats.push('Deaths <b>$deaths</b>');
		jEnd.html(
			'<div class="gp-end-box">' +
			'<div class="gp-end-title ${complete ? "gp-win" : "gp-lose"}">${complete ? "Level complete" : "Out of lives"}</div>' +
			'<div class="gp-end-stats">${stats.join("<br/>")}</div>' +
			'<div class="gp-end-btns"><button class="gp-replay">${complete ? "Replay" : "Try again"} (R)</button>' +
			'<button class="gp-end-close gray">Close (Esc)</button></div></div>'
		);
		jEnd.find(".gp-replay").click( _-> restart() );
		jEnd.find(".gp-end-close").click( _-> close() );
		jEnd.addClass("on");
	}

	// ── Input ─────────────────────────────────────────────────────────────

	function listen() {
		var w = js.Browser.window;
		onKeyDownFn = (ev:js.html.KeyboardEvent)-> {
			// Every key belongs to the game while it is open: LDtk and Heaps never see it
			ev.stopImmediatePropagation();
			ev.preventDefault();
			switch ev.code {
				case "Escape": close(); return;
				case "KeyR": if( !ev.repeat ) restart();
				case "KeyG": if( !ev.repeat ) setGhost( jGhost.prop("checked") != true );
				case "Enter": if( !ev.repeat && (won || over) ) restart();
				case _:
			}
			held.set(ev.code, true);
		};
		onKeyUpFn = (ev:js.html.KeyboardEvent)-> {
			ev.stopImmediatePropagation();
			ev.preventDefault();
			held.remove(ev.code);
		};
		onBlurFn = _-> held = new Map();
		w.addEventListener("keydown", onKeyDownFn, true);
		w.addEventListener("keyup", onKeyUpFn, true);
		w.addEventListener("blur", onBlurFn);
	}

	public function close() {
		if( current != this ) return;
		current = null;
		var w = js.Browser.window;
		w.removeEventListener("keydown", onKeyDownFn, true);
		w.removeEventListener("blur", onBlurFn);
		// Keep the keys that are still down (Esc) away from LDtk until they are released
		var pending = [ for( k in held.keys() ) k ];
		if( !pending.contains("Escape") ) pending.push("Escape");
		var upFn = onKeyUpFn;
		var tail : js.html.KeyboardEvent->Void = null;
		tail = (ev:js.html.KeyboardEvent)-> {
			if( !pending.contains(ev.code) ) return;
			ev.stopImmediatePropagation();
			pending.remove(ev.code);
			if( pending.length == 0 ) w.removeEventListener("keyup", tail, true);
		};
		w.removeEventListener("keyup", upFn, true);
		w.addEventListener("keyup", tail, true);
		haxe.Timer.delay( ()-> w.removeEventListener("keyup", tail, true), 3000 );
		if( raf >= 0 ) w.cancelAnimationFrame(raf);
		raf = -1;
		jRoot.remove();
	}

	// ── Loop and drawing ──────────────────────────────────────────────────

	function frame(now:Float) {
		if( current != this ) return;
		raf = js.Browser.window.requestAnimationFrame(frame);
		var dt = lastT < 0 ? 0 : Math.min((now - lastT) / 1000, 0.25);
		lastT = now;
		if( !debugPaused ) {
			acc += dt;
			while( acc >= PlayPlayer.DT ) {
				acc -= PlayPlayer.DT;
				tick();
			}
		}
		render();
	}

	function render() {
		var ratio = js.Browser.window.devicePixelRatio;
		var cw = Std.int(canvas.clientWidth * ratio), ch = Std.int(canvas.clientHeight * ratio);
		if( cw <= 0 || ch <= 0 ) return;
		if( canvas.width != cw || canvas.height != ch ) {
			canvas.width = cw;
			canvas.height = ch;
		}
		var c = ctx;
		c.setTransform(1, 0, 0, 1, 0, 0);
		c.imageSmoothingEnabled = false;
		c.fillStyle = "#14161c";
		c.fillRect(0, 0, cw, ch);
		if( player == null ) return;

		// Camera: follow the player, clamped to the level
		var lw = level.pxWid, lh = level.pxHei, ts = grid.ts;
		var scale = Math.max(1, Math.min(ch / Math.min(lh, VIEW_TILES_Y * ts), cw / Math.min(lw, VIEW_TILES_X * ts)));
		var vw = cw / scale, vh = ch / scale;
		var tx = vw >= lw ? (lw - vw) / 2 : M.fclamp(player.x - vw / 2, 0, lw - vw);
		var ty = vh >= lh ? (lh - vh) / 2 : M.fclamp(player.y - prof.height / 2 - vh / 2, 0, lh - vh);
		if( !camReady ) {
			camX = tx;
			camY = ty;
			camReady = true;
		}
		else {
			camX += (tx - camX) * 0.2;
			camY += (ty - camY) * 0.2;
		}
		var ox = Math.round(-camX * scale), oy = Math.round(-camY * scale);
		c.setTransform(scale, 0, 0, scale, ox, oy);
		c.drawImage(levelCanvas, 0, 0);

		drawStuck(c);
		if( jGhost.prop("checked") == true ) drawGhost(c, scale);
		for( e in entities ) drawEntity(c, e, scale);
		drawPlayer(c, scale);

		c.setTransform(ratio, 0, 0, ratio, 0, 0);
		drawHud(c, cw / ratio, ch / ratio);
	}

	function inStuckSpan() : Bool {
		if( stuck.length == 0 ) return false;
		var ts = grid.ts;
		var col = Std.int(Math.floor(player.x / ts)), row = Std.int(Math.floor((player.y - 0.5) / ts));
		for( sp in stuck )
			if( sp.row == row && col >= sp.col && col < sp.col + sp.w ) return true;
		return false;
	}

	function drawStuck(c:js.html.CanvasRenderingContext2D) {
		if( stuck.length == 0 ) return;
		var ts = grid.ts;
		c.fillStyle = "rgba(255,70,70,0.22)";
		for( sp in stuck ) c.fillRect(sp.col * ts, sp.row * ts, sp.w * ts, ts);
	}

	function drawGhost(c:js.html.CanvasRenderingContext2D, scale:Float) {
		if( route == null ) return;
		var steps : Array<Dynamic> = route.steps != null ? route.steps : [];
		c.lineWidth = 2 / scale;
		c.lineJoin = "round";
		c.setLineDash([4 / scale, 3 / scale]);
		c.strokeStyle = "rgba(255,240,140,0.45)";
		c.beginPath();
		for( st in steps ) {
			var pts : Array<Array<Float>> = st.points;
			if( pts == null || pts.length == 0 ) continue;
			c.moveTo(pts[0][0], pts[0][1]);
			for( i in 1...pts.length ) c.lineTo(pts[i][0], pts[i][1]);
		}
		c.stroke();
		c.setLineDash([]);
	}

	function drawEntity(c:js.html.CanvasRenderingContext2D, e:PlayEntity, scale:Float) {
		if( e.done || e.kind == "Start" ) return;
		var img = e.tile != null ? imageFor(e.tile.tilesetUid) : null;
		if( ready(img) )
			drawImage(c, img, e.tile.x, e.tile.y, e.tile.w, e.tile.h, e.x, e.y, e.w, e.h, e.kind == "Enemy" && e.dir < 0 ? 1 : 0);
		else {
			c.fillStyle = css(e.color, 0.85);
			c.fillRect(e.x, e.y, e.w, e.h);
			c.strokeStyle = "rgba(0,0,0,0.5)";
			c.lineWidth = 1 / scale;
			c.strokeRect(e.x, e.y, e.w, e.h);
		}
		if( e.kind == "Exit" && !exitOpen(e) ) {
			// Padlock
			var cx = e.x + e.w / 2, cy = e.y + e.h / 2;
			c.fillStyle = "rgba(20,20,28,0.85)";
			c.fillRect(cx - 4, cy - 1, 8, 6);
			c.strokeStyle = "rgba(20,20,28,0.85)";
			c.lineWidth = 1.5;
			c.beginPath();
			c.arc(cx, cy - 1, 2.6, Math.PI, 0);
			c.stroke();
		}
		if( e.kind == "Checkpoint" && e.x0 + e.w / 2 == checkX && e.y0 + e.h == checkY ) {
			c.strokeStyle = "rgba(120,220,255,0.9)";
			c.lineWidth = 1.5 / scale;
			c.strokeRect(e.x - 1, e.y - 1, e.w + 2, e.h + 2);
		}
	}

	function drawPlayer(c:js.html.CanvasRenderingContext2D, scale:Float) {
		var p = player, w = prof.width, h = prof.height;
		if( invulnerable > 0 && Std.int(invulnerable * 10) % 2 == 0 ) return;
		var l = p.x - w / 2, t = p.y - h;
		if( p.dashTicks > 0 ) {
			c.fillStyle = "rgba(255,170,60,0.35)";
			c.fillRect(l - p.dashDir * 10, t + 2, w, h - 4);
		}
		c.fillStyle = "#3fc8ff";
		c.fillRect(l, t, w, h);
		c.fillStyle = "#1b6f9a";
		c.fillRect(l, t + h - 3, w, 3);
		c.strokeStyle = "#0b2b3d";
		c.lineWidth = 1 / scale;
		c.strokeRect(l, t, w, h);
		// Eyes on the facing side
		c.fillStyle = "#ffffff";
		var ex = p.x + p.facing * w * 0.18;
		c.fillRect(ex - 2.5, t + 5, 2, 3);
		c.fillRect(ex + 0.5, t + 5, 2, 3);
	}

	function drawHud(c:js.html.CanvasRenderingContext2D, w:Float, h:Float) {
		var items = [ '♥ $lives' ];
		if( totalCoins > 0 ) items.push('● $coins/$totalCoins');
		if( totalGems > 0 ) items.push('◆ $gems/$totalGems');
		if( keys.length > 0 ) items.push('⚿ ${keys.length}');
		c.font = "bold 13px sans-serif";
		c.textBaseline = "middle";
		var text = items.join("    ");
		var tw = c.measureText(text).width;
		c.fillStyle = "rgba(10,12,16,0.7)";
		c.fillRect(8, 8, tw + 20, 26);
		c.fillStyle = "#f2f4f8";
		c.fillText(text, 18, 21);

		var tt = fmtTime(time);
		var ttw = c.measureText(tt).width;
		c.fillStyle = "rgba(10,12,16,0.7)";
		c.fillRect(w - ttw - 28, 8, ttw + 20, 26);
		c.fillStyle = "#f2f4f8";
		c.fillText(tt, w - ttw - 18, 21);

		if( toastT > 0 && toast.length > 0 ) {
			c.font = "bold 15px sans-serif";
			var mw = c.measureText(toast).width;
			c.globalAlpha = Math.min(1, toastT * 2);
			c.fillStyle = "rgba(10,12,16,0.75)";
			c.fillRect((w - mw) / 2 - 12, 44, mw + 24, 28);
			c.fillStyle = "#ffe14d";
			c.fillText(toast, (w - mw) / 2, 58);
			c.globalAlpha = 1;
		}
	}

	// ── Debug hook (debug builds only) ────────────────────────────────────

	#if debug
	static function installDebugHook() {
		var w : Dynamic = js.Browser.window;
		if( w.__gldtkPlay != null ) return;
		w.__gldtkPlay = {
			state: ()-> current == null ? null : current.debugState(),
			/** Stops (true) or resumes the real-time loop. **/
			pause: (b:Bool)-> { if( current != null ) current.debugPaused = b; },
			/** Runs `n` ticks with these keys held ({left, right, jump, dash}), then returns the state. **/
			step: (n:Int, k:Dynamic)-> {
				if( current == null ) return null;
				var g = current;
				g.forcedKeys = {
					left: k != null && k.left == true, right: k != null && k.right == true,
					jump: k != null && k.jump == true, dash: k != null && k.dash == true,
				};
				for( _ in 0...n ) g.tick();
				g.forcedKeys = null;
				return g.debugState();
			},
			/** Puts the player's feet at (x, y), at rest. **/
			teleport: (x:Float, y:Float)-> {
				if( current == null || current.player == null ) return null;
				current.player.reset(x, y);
				current.prevKeys = { left: false, right: false, jump: false, dash: false };
				current.camReady = false;
				return current.debugState();
			},
			restart: ()-> { if( current != null ) current.restart(); },
			close: ()-> { if( current != null ) current.close(); },
		};
	}

	function debugState() : Dynamic {
		var p = player;
		return {
			ready: p != null,
			x: p != null ? p.x : null, y: p != null ? p.y : null,
			vx: p != null ? p.vx : null, vy: p != null ? p.vy : null,
			grounded: p != null && p.grounded, facing: p != null ? p.facing : 0,
			lastMove: p != null ? p.lastMove : "",
			canDoubleJump: p != null && p.canDoubleJump, canDash: p != null && p.canDash,
			gravity: p != null ? p.gravity() : null,
			lives: lives, coins: coins, gems: gems, keys: keys.length, deaths: deaths,
			time: time, ticks: ticks, won: won, over: over,
			spawn: [spawnX, spawnY], checkpoint: [checkX, checkY],
			level: { iid: level.iid, w: grid.wid, h: grid.hei, ts: grid.ts },
			profile: prof, route: route != null,
			paused: debugPaused,
		};
	}
	#end
}
