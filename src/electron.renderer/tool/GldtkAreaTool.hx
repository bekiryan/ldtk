package tool;

typedef GldtkRect = { col:Int, row:Int, w:Int, h:Int }

/**
	GLDtk "Select area" mode: drag a rectangle on the level, snapped to the
	grid of `li` (the IntGrid layer). Runs as the Editor's special tool, like
	PickPoint, so it takes over left-clicks until a rectangle is drawn or the
	user presses Escape / right-clicks.
**/
class GldtkAreaTool extends Tool<Int> {
	var li : data.inst.LayerInstance;
	var prevLayer : Null<data.inst.LayerInstance>;
	var start : Null<{ cx:Int, cy:Int }>;

	public function new(li:data.inst.LayerInstance) {
		super();
		this.li = li;
		canUseOutOfBounds = true;

		// Start in the grid layer, so a drag that starts over an entity is not
		// taken over by the selection tool (Editor.onMouseDown). This runs before
		// Editor.setSpecialTool(), as selectLayerInstance() clears special tools.
		prevLayer = editor.curLayerInstance;
		if( prevLayer!=li )
			editor.selectLayerInstance(li, false);
	}

	override function onDispose() {
		super.onDispose();
		// Disposal is deferred: don't switch layers under a newer special tool
		if( prevLayer!=null && prevLayer!=li && !editor.destroyed && editor.curLayerInstance==li && !editor.isSpecialToolActive() )
			editor.selectLayerInstance(prevLayer, false);
		onEnd();
	}

	override function getDefaultValue() return 0; // Not actually used
	override function canEdit() return App.ME.hasGlContext;

	inline function cellX(m:Coords) return M.iclamp( Std.int( M.floor(m.levelX/li.def.gridSize) ), 0, li.cWid-1 );
	inline function cellY(m:Coords) return M.iclamp( Std.int( M.floor(m.levelY/li.def.gridSize) ), 0, li.cHei-1 );

	function rectTo(m:Coords) : GldtkRect {
		var x = cellX(m);
		var y = cellY(m);
		return {
			col: M.imin(start.cx, x),
			row: M.imin(start.cy, y),
			w: M.iabs(x-start.cx) + 1,
			h: M.iabs(y-start.cy) + 1,
		}
	}

	override function customCursor(ev:hxd.Event, m:Coords) {
		super.customCursor(ev, m);
		if( !isRunning() )
			editor.cursor.set( GridCell(li, cellX(m), cellY(m), 0xffcc00) );
		else
			editor.cursor.set(None);
		ev.cancel = true;
	}

	override function startUsing(ev:hxd.Event, m:Coords, ?extraParam:String) {
		curMode = null;
		if( ev.button==1 ) {
			editor.clearSpecialTool();
			return;
		}
		if( ev.button!=0 )
			return;

		curMode = Add;
		button = 0;
		origin = m;
		lastMouse = m;
		start = { cx:cellX(m), cy:cellY(m) };
		ev.cancel = true;
		onChange( rectTo(m) );
	}

	override function onMouseMove(ev:hxd.Event, m:Coords) {
		if( isRunning() && start!=null ) {
			onChange( rectTo(m) );
			App.ME.requestCpu();
		}
		lastMouse = m;
	}

	override function stopUsing(m:Coords) {
		if( isRunning() && start!=null ) {
			var r = rectTo(m);
			curMode = null;
			start = null;
			onSelect(r);
			editor.clearSpecialTool();
		}
		curMode = null;
	}

	/** Called while dragging. **/
	public dynamic function onChange(r:GldtkRect) {}
	/** Called once the mouse button is released. **/
	public dynamic function onSelect(r:GldtkRect) {}
	/** Called when the tool goes away (selection done, Escape, right-click, tool change). **/
	public dynamic function onEnd() {}
}
