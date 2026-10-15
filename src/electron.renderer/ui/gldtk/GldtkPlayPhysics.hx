package ui.gldtk;

typedef PlayKeys = { left:Bool, right:Bool, jump:Bool, dash:Bool }

/**
	Game Profile values used by play mode (`game/profile.py`, as sent by `GET /profile`).
	Missing values fall back to the Python defaults.
**/
class PlayProfile {
	public var name = "Untitled game";
	public var tileSize = 16.;
	public var gravity = 980.;
	public var jumpV = 600.;
	public var runSpeed = 200.;
	public var walkStep = 8.;
	public var width = 12.;
	public var height = 24.;
	public var doubleJump = false;
	public var doubleJumpV = 500.;
	public var dash = false;
	public var dashPx = 64.;
	public var dashAir = true;
	public var wallJump = false;
	public var wallJumpV = 550.;
	public var wallClimb = 160.;
	public var wallPush = 48.;

	public function new() {}

	public static function fromJson(j:Null<Dynamic>) : PlayProfile {
		var p = new PlayProfile();
		if( j == null ) return p;
		function num(path:String, def:Float) : Float {
			var o : Dynamic = j;
			for( k in path.split(".") ) {
				if( o == null ) return def;
				o = Reflect.field(o, k);
			}
			return o != null && Std.isOfType(o, Float) ? (o:Float) : def;
		}
		function flag(path:String, def:Bool) : Bool {
			var o : Dynamic = j;
			for( k in path.split(".") ) {
				if( o == null ) return def;
				o = Reflect.field(o, k);
			}
			return o == null ? def : o == true;
		}
		if( j.name != null ) p.name = Std.string(j.name);
		p.tileSize    = num("tile_size", p.tileSize);
		p.gravity     = num("physics.gravity", p.gravity);
		p.jumpV       = num("physics.jump_v", p.jumpV);
		p.runSpeed    = num("physics.run_speed", p.runSpeed);
		p.walkStep    = num("physics.walk_step_px", p.walkStep);
		p.width       = num("player.width_px", p.width);
		p.height      = num("player.height_px", p.height);
		p.doubleJump  = flag("abilities.double_jump.enabled", false);
		p.doubleJumpV = num("abilities.double_jump.jump_v", p.doubleJumpV);
		p.dash        = flag("abilities.dash.enabled", false);
		p.dashPx      = num("abilities.dash.distance_px", p.dashPx);
		p.dashAir     = flag("abilities.dash.air", true);
		p.wallJump    = flag("abilities.wall_jump.enabled", false);
		p.wallJumpV   = num("abilities.wall_jump.jump_v", p.wallJumpV);
		p.wallClimb   = num("abilities.wall_jump.max_climb_px", p.wallClimb);
		p.wallPush    = num("abilities.wall_jump.push_px", p.wallPush);
		return p;
	}
}

/**
	The level as play mode sees it: the IntGrid as solid / hazard cells and the
	section gravity (`symbolic/gravity.py`).

	Gravity follows `GravityField.from_cells`: one scale for the whole level,
	column bands (by the feet x) or row bands (by the hitbox centre y); any
	other layout uses column bands with each column's most common scale.
**/
class PlayGrid {
	public static inline var EMPTY  = 0;
	public static inline var SOLID  = 1;
	public static inline var HAZARD = 2;

	public var wid(default,null) : Int;
	public var hei(default,null) : Int;
	public var ts(default,null) : Float;
	var cells : Array<Int>;

	var gravityAxis = 0; // 0 uniform, 1 columns, 2 rows
	var scales : Array<Float> = [1.];

	public function new(wid:Int, hei:Int, ts:Float) {
		this.wid = wid;
		this.hei = hei;
		this.ts = ts;
		cells = [ for( _ in 0...wid*hei ) EMPTY ];
	}

	public inline function set(cx:Int, cy:Int, v:Int) cells[cx + cy*wid] = v;

	/** Outside the level: the sides are solid, above and below are open. **/
	public inline function get(cx:Int, cy:Int) : Int {
		return cx < 0 || cx >= wid ? SOLID : cy < 0 || cy >= hei ? EMPTY : cells[cx + cy*wid];
	}

	public inline function inside(cx:Int, cy:Int) return cx >= 0 && cx < wid && cy >= 0 && cy < hei;

	/** Sections as stored in `gldtk_sections` (inclusive cell bands). **/
	public function setSections(sections:Array<Dynamic>) {
		gravityAxis = 0;
		scales = [1.];
		if( sections == null || sections.length == 0 || wid == 0 || hei == 0 ) return;
		var bands = [];
		for( s in sections ) {
			if( s == null ) continue;
			var gs : Dynamic = s.gravity_scale;
			bands.push({
				c0: s.col_start != null ? Std.int(s.col_start) : 0,
				c1: s.col_end   != null ? Std.int(s.col_end)   : wid-1,
				r0: s.row_start != null ? Std.int(s.row_start) : 0,
				r1: s.row_end   != null ? Std.int(s.row_end)   : hei-1,
				g: gs != null && Std.isOfType(gs, Float) && (gs:Float) > 0 ? (gs:Float) : 1.,
			});
		}
		if( bands.length == 0 ) return;
		// edit.context.band_at: the band holding the cell, else the nearest one
		function scaleAt(c:Int, r:Int) : Float {
			for( b in bands )
				if( b.c0 <= c && c <= b.c1 && b.r0 <= r && r <= b.r1 )
					return b.g;
			var best = bands[0], bestD = 1e9;
			for( b in bands ) {
				var d = M.imax(0, M.imax(b.c0 - c, c - b.c1)) + M.imax(0, M.imax(b.r0 - r, r - b.r1));
				if( d < bestD ) { bestD = d; best = b; }
			}
			return best.g;
		}
		var grid = [ for( r in 0...hei ) [ for( c in 0...wid ) scaleAt(c, r) ] ];
		var first = grid[0][0];
		var uniform = true, byCol = true, byRow = true;
		for( r in 0...hei )
			for( c in 0...wid ) {
				var v = grid[r][c];
				if( v != first ) uniform = false;
				if( v != grid[0][c] ) byCol = false;
				if( v != grid[r][0] ) byRow = false;
			}
		if( uniform ) {
			scales = [first];
		}
		else if( byCol ) {
			gravityAxis = 1;
			scales = grid[0].copy();
		}
		else if( byRow ) {
			gravityAxis = 2;
			scales = [ for( r in 0...hei ) grid[r][0] ];
		}
		else {
			gravityAxis = 1;
			scales = [];
			for( c in 0...wid ) {
				var counts = new Map<String,Int>();
				var best = grid[0][c], bestN = 0;
				for( r in 0...hei ) {
					var k = Std.string(grid[r][c]);
					var n = (counts.exists(k) ? counts.get(k) : 0) + 1;
					counts.set(k, n);
					if( n > bestN ) { bestN = n; best = grid[r][c]; }
				}
				scales.push(best);
			}
		}
	}

	/** Gravity scale for a player with feet at (x, y) (level px, y down). **/
	public function gravityScale(x:Float, y:Float, playerHeight:Float) : Float {
		return switch gravityAxis {
			case 1: scales[ M.iclamp(Std.int(Math.floor(x / ts)), 0, wid-1) ];
			case 2: scales[ M.iclamp(Std.int(Math.floor((y - playerHeight/2) / ts)), 0, hei-1) ];
			case _: scales[0];
		}
	}
}

/**
	The player of play mode, with the motion model the verifier assumes
	(`symbolic/physics.py`, `symbolic/gravity.py`, `symbolic/walljump.py`).

	Level px, y down; (x, y) is the centre of the feet. The hitbox is the Game
	Profile's `width_px × height_px` above that point. One `step()` is one fixed
	1/60 s tick:

	- |vx| is run_speed or 0, with no acceleration (the verifier allows any
	  constant |vx| ≤ run_speed).
	- A jump sets vy = jump_v, then gravity is integrated exactly for the tick
	  (y += vy·dt + ½g·dt²) with the gravity of the section holding the player.
	- Releasing jump while rising continues on the arc of the lowest launch
	  speed the verifier tries (0.7 · jump_v, `LAUNCH_FRACTIONS`), so short and
	  long hops cover the same arcs.
	- Double jump: one mid-air jump that sets vy = double_jump.jump_v.
	- Dash: `distance_px` sideways over a few ticks while the vertical motion is
	  frozen — the verifier's instantaneous dash that costs no flight time.
	- Wall jump: in the air, with the whole hitbox beside a wall, jump kicks
	  with vy = min(kick speed, √(2·g·max_climb_px)), pushes away at run_speed
	  for push_px, then steers freely. Not twice in a row off the same wall face.
	- Collisions are axis separated AABB checks against the solid cells.
	  Contacts within 0.01 px do not count, as in the verifier. On the ground the
	  player steps up ledges up to walk_step_px; in the air up to 4 px
	  (`LAND_TOLERANCE_PX`: the verifier accepts a landing arc that clips the
	  target's edge by that much).
**/
class PlayPlayer {
	public static inline var DT = 1 / 60;
	public static inline var EPS = 0.01;            // _CONTACT_EPS
	public static inline var LAND_TOLERANCE = 4.0;  // LAND_TOLERANCE_PX
	public static inline var MIN_LAUNCH = 0.7;      // smallest of LAUNCH_FRACTIONS
	public static inline var DASH_TICKS = 6;
	static inline var MAX_MOVE = 4.0;               // px per collision sub-step

	public var p : PlayProfile;
	public var grid : PlayGrid;

	public var x = 0.;
	public var y = 0.;
	public var vx = 0.;
	public var vy = 0.;
	public var grounded = false;
	public var facing = 1;
	public var canDoubleJump = true;
	public var canDash = true;
	public var dashTicks = 0;
	public var dashDir = 1;
	public var pushTime = 0.;
	public var pushDir = 0;
	public var lastWall = "";      // wall face of the last kick (until landing)
	public var lastMove = "";      // "jump", "double_jump", "wall_jump", "dash" (debug / tests)

	var jumping = false;           // rising from a jump: releasing the key shortens it
	var launchY = 0.;
	var launchV = 0.;

	public function new(p:PlayProfile, grid:PlayGrid) {
		this.p = p;
		this.grid = grid;
	}

	public var hw(get,never) : Float; inline function get_hw() return p.width / 2;

	public function reset(x:Float, y:Float) {
		this.x = x;
		this.y = y;
		vx = vy = 0;
		facing = 1;
		dashTicks = 0;
		pushTime = 0;
		jumping = false;
		lastMove = "";
		grounded = onGround();
		land();
	}

	public inline function gravity() : Float return p.gravity * grid.gravityScale(x, y, p.height);

	function land() {
		canDoubleJump = true;
		canDash = true;
		lastWall = "";
	}

	/** One tick. `prev`: the keys of the previous tick (for presses and releases). **/
	public function step(k:PlayKeys, prev:PlayKeys) {
		var g = gravity();
		var dir = (k.right ? 1 : 0) - (k.left ? 1 : 0);
		if( dir != 0 && pushTime <= 0 ) facing = dir;

		// Dash
		if( k.dash && !prev.dash && p.dash && dashTicks <= 0 && canDash && (grounded || p.dashAir) ) {
			dashTicks = DASH_TICKS;
			dashDir = dir != 0 ? dir : facing;
			canDash = false;
			pushTime = 0;
			lastMove = "dash";
		}

		// Jumps: ground, wall kick, then double jump
		if( k.jump && !prev.jump && dashTicks <= 0 ) {
			var wall = grounded ? 0 : wallSide();
			if( grounded )
				launch(p.jumpV, "jump");
			else if( p.wallJump && wall != 0 && wallKey(wall) != lastWall ) {
				lastWall = wallKey(wall);
				var kick = p.wallClimb <= 0 ? 0. : Math.min(p.wallJumpV, Math.sqrt(2 * g * p.wallClimb));
				launch(kick, "wall_jump");
				pushDir = -wall;
				pushTime = p.runSpeed > 0 ? p.wallPush / p.runSpeed : 0;
				facing = pushDir;
			}
			else if( p.doubleJump && canDoubleJump ) {
				canDoubleJump = false;
				launch(p.doubleJumpV, "double_jump");
			}
		}

		// Short hop: continue on the arc of the lowest launch speed
		if( jumping && !k.jump ) {
			jumping = false;
			if( vy < 0 ) {
				var v0 = MIN_LAUNCH * launchV;
				var v = Math.sqrt( Math.max(0, v0*v0 - 2 * g * (launchY - y)) );
				if( v < -vy ) vy = -v;
			}
		}
		if( vy >= 0 ) jumping = false;

		if( dashTicks > 0 ) {
			dashTicks--;
			vx = dashDir * p.dashPx / (DASH_TICKS * DT);
			if( moveX(dashDir * p.dashPx / DASH_TICKS) ) dashTicks = 0;
			grounded = onGround();
			if( grounded ) land();
			return;
		}

		vx = pushTime > 0 ? pushDir * p.runSpeed : dir * p.runSpeed;
		if( pushTime > 0 ) pushTime -= DT;
		if( moveX(vx * DT) ) vx = 0;

		var dy = vy * DT + 0.5 * g * DT * DT;
		vy += g * DT;
		if( moveY(dy) ) {
			if( vy < 0 ) jumping = false;
			vy = 0;
		}
		grounded = vy >= 0 && onGround();
		if( grounded ) {
			vy = 0;
			land();
		}
	}

	function launch(v:Float, move:String) {
		vy = -v;
		launchY = y;
		launchV = v;
		jumping = true;
		grounded = false;
		lastMove = move;
	}

	// ── Collisions ──────────────────────────────────────────────────────

	/** Any solid cell (or the level's side) under the hitbox with feet at (x, y). **/
	public function hits(x:Float, y:Float) : Bool {
		var ts = grid.ts;
		var left = x - hw + EPS, right = x + hw - EPS;
		if( left < 0 || right > grid.wid * ts ) return true;
		var c0 = Std.int(Math.floor(left / ts)), c1 = Std.int(Math.floor(right / ts));
		var r0 = Std.int(Math.floor((y - p.height + EPS) / ts)), r1 = Std.int(Math.floor((y - EPS) / ts));
		for( r in r0...r1+1 )
			for( c in c0...c1+1 )
				if( grid.get(c, r) == PlayGrid.SOLID )
					return true;
		return false;
	}

	/** Cells of `kind` overlapping the hitbox shrunk by `inset` px. **/
	public function touches(kind:Int, inset:Float) : Bool {
		var ts = grid.ts;
		var c0 = Std.int(Math.floor((x - hw + inset) / ts)), c1 = Std.int(Math.floor((x + hw - inset) / ts));
		var r0 = Std.int(Math.floor((y - p.height + inset) / ts)), r1 = Std.int(Math.floor((y - inset) / ts));
		for( r in r0...r1+1 )
			for( c in c0...c1+1 )
				if( grid.inside(c, r) && grid.get(c, r) == kind )
					return true;
		return false;
	}

	public function onGround() : Bool return !hits(x, y) && hits(x, y + 0.5);

	/** Moves sideways; true when blocked. **/
	function moveX(dx:Float) : Bool {
		var ts = grid.ts;
		while( dx != 0 ) {
			var d = M.fclamp(dx, -MAX_MOVE, MAX_MOVE);
			dx -= d;
			var nx = x + d;
			if( !hits(nx, y) ) {
				x = nx;
				continue;
			}
			var up = stepUp(nx);
			if( up > 0 ) {
				x = nx;
				y -= up;
				continue;
			}
			// Snap against the blocking column (or the level's side)
			if( d > 0 ) {
				var right = nx + hw - EPS;
				x = right > grid.wid * ts ? grid.wid * ts - hw : Math.max(x, Math.floor(right / ts) * ts - hw);
			}
			else {
				var left = nx - hw + EPS;
				x = left < 0 ? hw : Math.min(x, (Math.floor(left / ts) + 1) * ts + hw);
			}
			if( hits(x, y) ) x = nx - d;
			return true;
		}
		return false;
	}

	/** How far up the player must go to stand on what blocks it at `nx` (0: not allowed). **/
	function stepUp(nx:Float) : Float {
		var max = grounded ? p.walkStep : LAND_TOLERANCE;
		if( max <= 0 ) return 0;
		var ts = grid.ts;
		var c0 = Std.int(Math.floor((nx - hw + EPS) / ts)), c1 = Std.int(Math.floor((nx + hw - EPS) / ts));
		var r0 = Std.int(Math.floor((y - p.height + EPS) / ts)), r1 = Std.int(Math.floor((y - EPS) / ts));
		var top = 1e9;
		for( r in r0...r1+1 )
			for( c in c0...c1+1 )
				if( grid.get(c, r) == PlayGrid.SOLID && grid.inside(c, r) )
					top = Math.min(top, r * ts);
		if( top == 1e9 ) return 0;
		var up = y - top;
		return up > 0 && up <= max + 1e-6 && !hits(nx, top) ? up : 0;
	}

	/** Moves vertically; true when blocked (landed or bumped the head). **/
	function moveY(dy:Float) : Bool {
		var ts = grid.ts;
		while( dy != 0 ) {
			var d = M.fclamp(dy, -MAX_MOVE, MAX_MOVE);
			dy -= d;
			var ny = y + d;
			if( !hits(x, ny) ) {
				y = ny;
				continue;
			}
			if( d > 0 )
				y = Math.max(y, Math.floor((ny - EPS) / ts) * ts);
			else
				y = Math.min(y, (Math.floor((ny - p.height + EPS) / ts) + 1) * ts + p.height);
			if( hits(x, y) ) y = ny - d;
			return true;
		}
		return false;
	}

	/**
		Side (-1 left, 1 right) of a wall the whole hitbox is beside, else 0
		(`symbolic/walljump.py` wall faces: solid cells along the full height).
	**/
	public function wallSide() : Int {
		for( side in [1, -1] ) {
			var px = side > 0 ? x + hw + 0.5 : x - hw - 0.5;
			var c = Std.int(Math.floor(px / grid.ts));
			var r0 = Std.int(Math.floor((y - p.height + EPS) / grid.ts)), r1 = Std.int(Math.floor((y - EPS) / grid.ts));
			var all = true;
			for( r in r0...r1+1 )
				if( !grid.inside(c, r) || grid.get(c, r) != PlayGrid.SOLID ) {
					all = false;
					break;
				}
			if( all ) return side;
		}
		return 0;
	}

	function wallKey(side:Int) : String {
		var px = side > 0 ? x + hw + 0.5 : x - hw - 0.5;
		return Std.int(Math.floor(px / grid.ts)) + (side > 0 ? "R" : "L");
	}
}
