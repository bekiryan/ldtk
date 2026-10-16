package ui;

/**
	GLDtk golden route overlay (v3 Part 13): draws a route from the server
	(`/route`, or the `route` of a generate / edit / undo response) over the level.

	The graphics live in `levelRender.root`, in level pixels, so they follow the
	camera's pan and zoom like the level itself. Line widths are divided by the
	zoom, so call `draw()` again after a zoom change to keep them constant on
	screen. An `h2d.Graphics` takes no mouse input, and the overlay never touches
	the project data, so it cannot mark the project as modified.
**/
class GldtkRouteOverlay {
	static inline var WALK_COLOR   = 0x8fe9ff;
	static inline var JUMP_COLOR   = 0xffe14d;
	static inline var FALL_COLOR   = 0x5fb4ff;
	static inline var DOUBLE_COLOR = 0xff6bd9;
	static inline var DASH_COLOR   = 0xff9a2e;
	static inline var WALL_COLOR   = 0xb58cff;
	static inline var REACH_COLOR  = 0x4dff88;
	static inline var RING_COLOR   = 0xff3b3b;
	static inline var STUCK_COLOR  = 0xff2a2a;

	var g : Null<h2d.Graphics>;

	public function new() {}

	static function colorOf(kind:String) : Int {
		return switch kind {
			case "walk": WALK_COLOR;
			case "fall": FALL_COLOR;
			case "double_jump": DOUBLE_COLOR;
			case "dash": DASH_COLOR;
			case "wall_jump": WALL_COLOR;
			case _: JUMP_COLOR;
		}
	}

	/** Graphics in the current level render, recreated with the Editor. **/
	function graphics() : Null<h2d.Graphics> {
		var editor = Editor.ME;
		if( editor == null || editor.destroyed || editor.levelRender == null || editor.levelRender.root == null )
			return null;
		var root = editor.levelRender.root;
		if( g == null || g.parent != root ) {
			if( g != null ) g.remove();
			g = new h2d.Graphics();
			root.add(g, Const.DP_TOP);
		}
		return g;
	}

	public function clear() {
		if( g != null ) {
			g.clear();
			App.ME.requestCpu();
		}
	}

	/** Draws *route* over *level*, only if it is the level the route was computed for. **/
	public function draw(route:Null<Dynamic>, level:Null<data.Level>, gridSize:Int) {
		var g = graphics();
		if( g == null ) return;
		g.clear();
		App.ME.requestCpu();
		if( route == null || level == null ) return;
		if( route.level_iid != null && route.level_iid != level.iid ) return;

		// One screen pixel, in level pixels
		var px = 1 / M.fmax(Editor.ME.camera.adjustedZoom, 0.05);

		// Reachable spans: a span is the row of solid tiles; the player stands in the cells above
		var spans : Array<Dynamic> = route.reachable_spans != null ? route.reachable_spans : [];
		g.lineStyle();
		for( s in spans ) {
			var x = s.col*gridSize, y = s.row*gridSize, w = s.w*gridSize;
			g.beginFill(REACH_COLOR, 0.13);
			g.drawRect(x, y-gridSize, w, gridSize);
			g.endFill();
			g.beginFill(REACH_COLOR, 0.5);
			g.drawRect(x, y - M.fmax(1, 1.5*px), w, M.fmax(1, 1.5*px));
			g.endFill();
		}

		// Soft-locks: spans where the player gets stuck, shaded red over the reachable shading
		var stuck : Array<Dynamic> = route.softlock_spans != null ? route.softlock_spans : [];
		for( s in stuck ) {
			var x = s.col*gridSize, y = s.row*gridSize, w = s.w*gridSize;
			g.beginFill(STUCK_COLOR, 0.3);
			g.drawRect(x, y-gridSize, w, gridSize);
			g.endFill();
			g.beginFill(STUCK_COLOR, 0.85);
			g.drawRect(x, y - M.fmax(1, 2*px), w, M.fmax(1, 2*px));
			g.endFill();
		}

		var steps : Array<Dynamic> = route.steps != null ? route.steps : [];
		for( st in steps ) {
			var pts : Array<Array<Float>> = st.points;
			if( pts == null || pts.length < 2 ) continue;
			var kind : String = st.kind;
			var col = colorOf(kind);
			if( kind == "walk" ) {
				g.lineStyle(2*px, col, 0.9);
				g.moveTo(pts[0][0], pts[0][1]);
				for( i in 1...pts.length )
					g.lineTo(pts[i][0], pts[i][1]);
				g.lineStyle();
			}
			else
				dots(g, pts, col, kind == "fall" ? 1.2*px : 1.5*px, 5*px);
			arrow(g, pts, col, px);
		}

		var iids : Array<String> = route.unreachable_required != null ? route.unreachable_required : [];
		for( iid in iids ) {
			var ei = findEntity(level, iid);
			if( ei == null ) continue;
			var r = M.fmax(ei.width, ei.height) * 0.75 + 3*px;
			g.lineStyle(2.5*px, RING_COLOR, 0.95);
			g.drawCircle(ei.centerX, ei.centerY, r);
			g.lineStyle(1*px, 0xffffff, 0.5);
			g.drawCircle(ei.centerX, ei.centerY, r + 2*px);
			g.lineStyle();
		}
	}

	static function findEntity(level:data.Level, iid:String) : Null<data.inst.EntityInstance> {
		for( li in level.layerInstances )
			for( ei in li.entityInstances )
				if( ei.iid == iid )
					return ei;
		return null;
	}

	/** Dots every *spacing* px along the polyline. **/
	static function dots(g:h2d.Graphics, pts:Array<Array<Float>>, col:Int, radius:Float, spacing:Float) {
		var carry = 0.;
		g.lineStyle();
		g.beginFill(col, 0.95);
		g.drawCircle(pts[0][0], pts[0][1], radius);
		for( i in 1...pts.length ) {
			var ax = pts[i-1][0], ay = pts[i-1][1];
			var dx = pts[i][0] - ax, dy = pts[i][1] - ay;
			var len = Math.sqrt(dx*dx + dy*dy);
			if( len <= 0 ) continue;
			var d = spacing - carry;
			while( d <= len ) {
				g.drawCircle(ax + dx*d/len, ay + dy*d/len, radius);
				d += spacing;
			}
			carry = len - (d - spacing);
		}
		g.endFill();
	}

	/** Arrowhead at the end of the polyline, pointing along its last few pixels. **/
	static function arrow(g:h2d.Graphics, pts:Array<Array<Float>>, col:Int, px:Float) {
		var n = pts.length;
		var tx = pts[n-1][0], ty = pts[n-1][1];
		var i = n - 2;
		while( i > 0 && Math.sqrt(Math.pow(tx - pts[i][0], 2) + Math.pow(ty - pts[i][1], 2)) < 6 )
			i--;
		var dx = tx - pts[i][0], dy = ty - pts[i][1];
		var len = Math.sqrt(dx*dx + dy*dy);
		if( len <= 0 ) return;
		dx /= len; dy /= len;
		var size = 6*px;
		var bx = tx - dx*size, by = ty - dy*size;
		var nx = -dy * size*0.55, ny = dx * size*0.55;
		g.lineStyle(0.75*px, 0x000000, 0.6);
		g.beginFill(col, 1);
		g.moveTo(tx, ty);
		g.lineTo(bx + nx, by + ny);
		g.lineTo(bx - nx, by - ny);
		g.lineTo(tx, ty);
		g.endFill();
		g.lineStyle();
	}
}
