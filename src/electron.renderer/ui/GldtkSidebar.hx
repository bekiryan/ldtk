package ui;

typedef ProfileField = { path:String, label:String, ?bool:Bool }
typedef ProfileGroup = { title:String, ?toggle:String, fields:Array<ProfileField> }
typedef EditMode = { id:String, label:String, action:String }
typedef GldtkRect = tool.GldtkAreaTool.GldtkRect
typedef GldtkJob = { id:String, startedAt:Float, timer:Null<haxe.Timer>, polling:Bool, cancelling:Bool }

/**
  GLDtk sidebar — persistent right-hand panel, styled to match LDtk's
  native design. Uses XMLHttpRequest so it runs through Electron's renderer
  XHR stack rather than Node's http module.

  Output path is always the currently open project file — no manual input.
**/
class GldtkSidebar {

	static var SERVER       = "http://127.0.0.1:" + (js.Node.process.env.exists("GLDTK_PORT") ? js.Node.process.env.get("GLDTK_PORT") : "8765"); // set by the main process in the packaged app
	static inline var HIST_KEY     = "gldtk_history";
	static inline var PROVIDER_KEY = "gldtk_provider";
	static inline var MODEL_KEY    = "gldtk_model";
	static inline var PROFILE_KEY  = "gldtk_profile_open";
	static inline var MEMORY_KEY   = "gldtk_memory_open";
	static var STRUCTURES = ["corridor","parkour","labyrinth","arena","shaft","hub","open"];
	static var MEMORY_STATS = ["gap","enemy_spacing_median","removed_kinds","undo_rate"];
	static inline var EDIT_KEY     = "gldtk_edit_open";
	static inline var MODE_KEY     = "gldtk_edit_mode";
	static inline var ROUTE_KEY    = "gldtk_route_on";
	static inline var ROUTE_DEBOUNCE_MS = 800;
	static inline var DIFF_DEBOUNCE_MS = 800;
	static inline var PROGRESS_POLL_MS  = 1000;

	// Overlay colours on the level canvas
	static inline var AREA_COLOR    = 0xffcc00;
	static inline var SECTION_COLOR = 0x4fb8ff;
	static inline var LOCATE_COLOR  = 0xe34d00;

	static var PROVIDERS = ["gemini", "anthropic", "ollama", "openai", "deepseek"];
	static var STATUSES  = ["satisfied", "approximated", "impossible", "missing", "unchecked"];

	static var EDIT_MODES : Array<EditMode> = [
		{ id: "region",   label: "Region",   action: "Regenerate area" },
		{ id: "section",  label: "Section",  action: "Regenerate section" },
		{ id: "entities", label: "Entities", action: "Edit entities" },
		{ id: "describe", label: "Describe", action: "Find location" },
	];

	// Game Profile fields shown in the panel (paths into GET /profile)
	static var PROFILE_GROUPS : Array<ProfileGroup> = [
		{ title: "Physics", fields: [
			{ path: "physics.gravity",      label: "Gravity (px/s²)" },
			{ path: "physics.jump_v",       label: "Jump speed (px/s)" },
			{ path: "physics.run_speed",    label: "Run speed (px/s)" },
			{ path: "physics.walk_step_px", label: "Walk step (px)" },
		]},
		{ title: "Double jump", toggle: "abilities.double_jump.enabled", fields: [
			{ path: "abilities.double_jump.jump_v", label: "Jump speed (px/s)" },
		]},
		{ title: "Dash", toggle: "abilities.dash.enabled", fields: [
			{ path: "abilities.dash.distance_px", label: "Distance (px)" },
			{ path: "abilities.dash.air",         label: "Usable mid-air", bool: true },
		]},
		{ title: "Wall jump", toggle: "abilities.wall_jump.enabled", fields: [
			{ path: "abilities.wall_jump.jump_v",       label: "Kick speed (px/s)" },
			{ path: "abilities.wall_jump.max_climb_px", label: "Max climb (px)" },
			{ path: "abilities.wall_jump.push_px",      label: "Push (px)" },
		]},
	];

	var jRoot      : J;
	var jToggle    : J;
	var jHistory   : J;
	var jPrompt    : J;
	var jBtn       : J;
	var jStatus    : J;
	var jFile      : J;
	var jProvider  : J;
	var jModel     : J;
	var jProfHead  : J;
	var jProfNote  : J;
	var jProf      : J;
	var jProfErr   : J;
	var jEditHead  : J;
	var jEditNote  : J;
	var jEdit      : J;
	var jAreaBtn   : J;
	var jTarget    : J;
	var jSection   : J;
	var jStructure : J;
	var jMemHead   : J;
	var jMemNote   : J;
	var jMem       : J;
	var memory     : Null<Dynamic>;
	var jLocText   : J;
	var jLocated   : J;
	var jEditPrompt: J;
	var jEditBtn   : J;
	var jUndo      : J;
	var jRouteOn   : J;
	var jRouteSum  : J;
	var jDiff      : J;
	var jProgress  : J;
	var jProgMsg   : J;
	var jProgTime  : J;
	var jProgLog   : J;
	var collapsed  : Bool   = false;
	var busy       : Bool   = false;

	var defaultModels : Map<String,String> = new Map();
	var profile       : Null<Dynamic>;   // last profile loaded from or saved to the server
	var profilePath   : Null<String>;    // project the profile belongs to

	// Regional editing (Part 8)
	var editMode    : String = "region";
	var area        : Null<GldtkRect>;   // rectangle drawn with "Select area"
	var dragArea    : Null<GldtkRect>;   // rectangle being dragged
	var located     : Null<{ rect:GldtkRect, explanation:String }>; // Describe result awaiting confirmation
	var sections    : Array<Dynamic> = []; // parsed gldtk_sections of the current level
	var snapshots   : Array<Dynamic> = []; // GET /history, newest first
	var editPath    : Null<String>;      // project the selection belongs to
	var overlay     : Null<h2d.Graphics>;

	// Golden route (v3 Part 13)
	var routeOverlay      = new GldtkRouteOverlay();
	var route             : Null<Dynamic>;     // RouteModel of `routePath`
	var routePath         : Null<String>;
	var routeSeq          = 0;                 // bumped to drop stale /route answers
	var routeTimer        : Null<haxe.Timer>;  // debounced refetch
	var routeFromResponse = false;             // `route` came with a result: the reload needs no refetch

	// Difficulty chart (v3 Part 15b)
	var difficulty        : Null<Dynamic>;     // DifficultyModel of `difficultyPath`
	var difficultyPath    : Null<String>;
	var difficultySeq     = 0;                 // bumped to drop stale /difficulty answers
	var difficultyTimer   : Null<haxe.Timer>;
	var difficultyFromResponse = false;

	// Multi-level worlds (v3 Part 17b)
	var levelInfo         : Map<String,Dynamic> = new Map(); // level iid -> { title, score, verified } of `levelInfoPath`
	var levelInfoPath     : Null<String>;
	var fullReload        = false;             // the next reload brings new levels
	var reselectIid       : Null<String>;      // level to select again once the project is reloaded
	var jLevels           : J;                 // "Levels" select next to Generate
	var jLevelBox         : J;
	var jLevelList        : J;
	var jLevelEditing     : J;

	// Live progress + Cancel (v3 Part 14)
	var job : Null<GldtkJob>;                  // the running generate / edit / locate

	public function new() {
		injectCss();
		buildDom();
		restoreState();
		restoreHistory();
		loadProviders();
		loadSettings();
		onProjectChanged();
	}

	/** First launch of the packaged app: no Gemini key yet, so show the key form. **/
	function loadSettings() {
		var jBox = jRoot.find("#g-key-box");
		var jKey = jRoot.find("#g-key");
		var jMsg = jRoot.find("#g-key-msg");
		jRoot.find("#g-key-save").click( (_)->{
			var key = StringTools.trim( jKey.val() );
			if( key == "" ) return;
			request("POST", "/settings", { gemini_api_key:key }, (status, res)->{
				if( status == 200 && res != null && res.has_key ) {
					jKey.val("");
					jBox.hide();
				}
				else
					jMsg.text("Could not save the key");
			}, ()->jMsg.text("server offline") );
		});
		request("GET", "/settings", null, (status, res)->{
			if( status == 200 && res != null && !res.has_key )
				jBox.show();
		}, ()->{} );
	}

	// ── CSS ───────────────────────────────────────────────────────────────

	function injectCss() {
		if( new J("#gldtk-style").length > 0 ) return;
		new J("head").append('<link id="gldtk-style" rel="stylesheet" href="css/gldtk-sidebar.css"/>');
	}

	// ── DOM ───────────────────────────────────────────────────────────────

	function buildDom() {
		jToggle = new J('<button id="gldtk-toggle">AI</button>');
		jToggle.click( _-> toggleCollapse() );
		jToggle.toggleClass("open", !collapsed);
		new J("body").append(jToggle);

		var providerOpts = PROVIDERS.map( p->'<option value="$p">$p</option>' ).join("");
		var modeBtns = EDIT_MODES.map( m->'<button class="g-mode-btn" data-mode="${m.id}">${m.label}</button>' ).join("");

		jRoot = new J('<div id="gldtk-root"></div>');
		jRoot.html('
			<div class="g-titlebar">
				<span class="g-title">GLDtk</span>
				<span class="g-status" id="g-status">ready</span>
				<button class="g-clear" id="g-clear" title="Clear the chat history">clear</button>
			</div>

			<div class="g-progress" id="g-progress">
				<div class="g-prog-line">
					<span class="g-prog-msg" id="g-prog-msg"></span>
					<span class="g-prog-time" id="g-prog-time"></span>
				</div>
				<details class="g-prog-fold">
					<summary>Log</summary>
					<ol class="g-prog-log" id="g-prog-log"></ol>
				</details>
			</div>

			<div class="g-history" id="g-history"></div>

			<div class="g-form">

				<div class="g-file-row" id="g-file-row">
					<span class="g-file-label">No project open</span>
				</div>

				<div class="g-levels" id="g-level-box">
					<div class="g-levels-editing" id="g-level-editing"></div>
					<div class="g-level-list" id="g-level-list"></div>
					<button id="g-regen" class="g-small-btn" title="Generate this level again with its own prompt; the other levels and the links stay">&#x21BB; Regenerate this level</button>
				</div>

				<div class="g-play-row">
					<button id="g-play" class="g-play-btn" title="Play the level with the Game Profile physics (Esc to close)">&#x25B6;&nbsp; Play</button>
				</div>

				<div class="g-route-row">
					<label class="g-route-toggle" title="Draw the cheapest Start → Exit route over the level">
						<input type="checkbox" id="g-route-on"/>Show route
					</label>
					<span class="g-route-sum" id="g-route-sum"></span>
				</div>

				<div class="g-diff" id="g-diff"></div>

				<div class="g-fold-head" id="g-prof-head">
					<span class="g-caret"></span>GAME PROFILE
					<span class="g-hint" id="g-prof-note"></span>
				</div>
				<div class="g-prof" id="g-prof">
					${profileFormHtml()}
					<div class="g-prof-err" id="g-prof-err"></div>
					<button class="g-prof-save" id="g-prof-save">Save profile</button>
				</div>

				<div class="g-fold-head" id="g-mem-head">
					<span class="g-caret"></span>DESIGN MEMORY
					<span class="g-hint" id="g-mem-note"></span>
				</div>
				<div class="g-prof g-mem" id="g-mem"></div>

				<div class="g-fold-head" id="g-edit-head">
					<span class="g-caret"></span>EDIT
					<span class="g-hint" id="g-edit-note"></span>
				</div>
				<div class="g-edit" id="g-edit">
					<div class="g-field g-mode-row">$modeBtns</div>
					<div class="g-field g-area-row" data-modes="region entities">
						<button id="g-area-btn" class="g-small-btn" title="Drag a rectangle on the level (Esc to cancel)">Select area</button>
						<span class="g-target" id="g-target"></span>
						<button id="g-area-clear" class="g-x" title="Clear the area">&times;</button>
					</div>
					<div class="g-field" data-modes="section">
						<select id="g-section"></select>
						<select id="g-structure" class="g-structure" title="Re-shape the selected section (no LLM)">
							<option value="">Make this section a…</option>
							${STRUCTURES.map( t->'<option value="$t">Make this section a $t</option>' ).join("")}
						</select>
					</div>
					<div class="g-field" data-modes="describe">
						<input id="g-loc" type="text" placeholder="Where? eg. the gap before the boss"/>
					</div>
					<div class="g-located" id="g-located"></div>
					<div class="g-field">
						<textarea id="g-edit-prompt" rows="2" placeholder="What should be there…"></textarea>
					</div>
					<div class="g-field">
						<button id="g-edit-btn" class="g-edit-btn"></button>
					</div>
					<div class="g-field">
						<button id="g-undo" class="g-undo-btn" disabled>&#x21B6; Undo last GLDtk edit</button>
					</div>
				</div>

				<div class="g-section">PROVIDER</div>
				<div class="g-field g-provider-row">
					<select id="g-provider">$providerOpts</select>
					<input id="g-model" type="text" placeholder="default model"/>
				</div>
				<div class="g-field" id="g-key-box" style="display:none">
					<div>Add your Gemini API key</div>
					<input id="g-key" type="password" placeholder="Gemini API key" autocomplete="off"/>
					<button id="g-key-save">Save key</button>
					<div id="g-key-msg"></div>
				</div>

				<div class="g-section">PROMPT</div>
				<div class="g-field">
					<textarea id="g-prompt" rows="4"
					          placeholder="Describe the level… (Ctrl+Enter to generate)"></textarea>
				</div>

				<div class="g-field g-gen-row">
					<select id="g-levels" title="Number of levels: Auto lets the prompt decide">
						<option value="">Levels: Auto</option>
						${[1,2,3,4,5,6,7,8].map( n->'<option value="$n">Levels: $n</option>' ).join("")}
					</select>
					<button id="g-btn" class="g-gen-btn">&#x25B6;&nbsp; Generate</button>
				</div>

			</div>
		');
		new J("body").append(jRoot);

		jHistory  = jRoot.find("#g-history");
		jPrompt   = jRoot.find("#g-prompt");
		jBtn      = jRoot.find("#g-btn");
		jStatus   = jRoot.find("#g-status");
		jFile     = jRoot.find("#g-file-row");
		jProvider = jRoot.find("#g-provider");
		jModel    = jRoot.find("#g-model");
		jProfHead = jRoot.find("#g-prof-head");
		jProfNote = jRoot.find("#g-prof-note");
		jProf     = jRoot.find("#g-prof");
		jStructure  = jRoot.find("#g-structure");
		jMemHead    = jRoot.find("#g-mem-head");
		jMemNote    = jRoot.find("#g-mem-note");
		jMem        = jRoot.find("#g-mem");
		jProfErr  = jRoot.find("#g-prof-err");

		jProgress = jRoot.find("#g-progress");
		jProgMsg  = jRoot.find("#g-prog-msg");
		jProgTime = jRoot.find("#g-prog-time");
		jProgLog  = jRoot.find("#g-prog-log");

		jLevels      = jRoot.find("#g-levels");
		jLevelBox    = jRoot.find("#g-level-box");
		jLevelList   = jRoot.find("#g-level-list");
		jLevelEditing = jRoot.find("#g-level-editing");
		jLevelList.on("click", ".g-lv", function(ev:js.jquery.Event) {
			var editor = activeEditor();
			if( editor == null || busy ) return;
			var iid = new J(ev.currentTarget).attr("data-iid");
			for( l in editor.curWorld.levels )
				if( l.iid == iid ) { editor.selectLevel(l, true); break; }
		});
		jRoot.find("#g-regen").click( _-> if( !busy ) regenerateLevel() );

		jBtn.click( _-> if( job != null ) cancelJob() else if( !busy ) generate() );
		jRoot.find("#g-clear").click( _-> clearHistory() );

		jPrompt.on("keydown", function(ev:js.jquery.Event) {
			var ke : js.html.KeyboardEvent = cast Reflect.field(ev, "originalEvent");
			if( ke != null && ke.key == "Enter" && (ke.ctrlKey || ke.metaKey) && !busy ) generate();
			if( ke != null && ke.key == "Escape" && job != null ) { ev.preventDefault(); cancelJob(); }
		});

		jProvider.change( _-> {
			saveStr(PROVIDER_KEY, jProvider.val());
			updateModelPlaceholder();
		});
		jModel.on("input", _-> saveStr(MODEL_KEY, StringTools.trim(jModel.val())) );

		jProfHead.click( _-> setProfileOpen( !jProfHead.hasClass("open") ) );
		jMemHead.click( _-> setMemoryOpen( !jMemHead.hasClass("open") ) );
		jStructure.change( _-> applyStructure() );
		bindMemory();
		jRoot.find("#g-prof-save").click( _-> saveProfile() );
		jProf.find("input[type=checkbox]").change( _-> updateAbilityToggles() );

		jEditHead   = jRoot.find("#g-edit-head");
		jEditNote   = jRoot.find("#g-edit-note");
		jEdit       = jRoot.find("#g-edit");
		jAreaBtn    = jRoot.find("#g-area-btn");
		jTarget     = jRoot.find("#g-target");
		jSection    = jRoot.find("#g-section");
		jLocText    = jRoot.find("#g-loc");
		jLocated    = jRoot.find("#g-located");
		jEditPrompt = jRoot.find("#g-edit-prompt");
		jEditBtn    = jRoot.find("#g-edit-btn");
		jUndo       = jRoot.find("#g-undo");
		jRouteOn    = jRoot.find("#g-route-on");
		jRouteSum   = jRoot.find("#g-route-sum");
		jDiff       = jRoot.find("#g-diff");
		jDiff.on("mouseenter", ".g-diff-bar", function(ev:js.jquery.Event) {
			var id = new J(ev.currentTarget).attr("data-id");
			for( s in sections )
				if( s.id == id ) { bleepRect(sectionRect(s), SECTION_COLOR); break; }
		});

		jEditHead.click( _-> setEditOpen( !jEditHead.hasClass("open") ) );
		jEdit.find(".g-mode-btn").click( (ev:js.jquery.Event)-> setEditMode( new J(ev.currentTarget).attr("data-mode") ) );
		jEdit.on("mouseenter", _-> refreshTarget() ); // the entity selection has no change event
		jAreaBtn.click( _-> startAreaSelection() );
		jRoot.find("#g-area-clear").click( _-> { area = null; refreshTarget(); drawOverlay(); } );
		jSection.change( _-> { refreshTarget(); drawOverlay(); bleepRect(selectedSectionRect(), SECTION_COLOR); } );
		jEditBtn.click( _-> if( job != null ) cancelJob() else if( !busy ) applyEdit() );
		jUndo.click( _-> if( !busy ) undo() );
		jRoot.find("#g-play").click( _-> play() );
		jRouteOn.change( _-> {
			saveStr(ROUTE_KEY, jRouteOn.prop("checked") ? "1" : "0");
			drawRoute();
		});
		jEditPrompt.on("keydown", function(ev:js.jquery.Event) {
			var ke : js.html.KeyboardEvent = cast Reflect.field(ev, "originalEvent");
			if( ke != null && ke.key == "Enter" && (ke.ctrlKey || ke.metaKey) && !busy ) applyEdit();
			if( ke != null && ke.key == "Escape" && job != null ) { ev.preventDefault(); cancelJob(); }
		});
		jLocText.on("keydown", function(ev:js.jquery.Event) {
			var ke : js.html.KeyboardEvent = cast Reflect.field(ev, "originalEvent");
			if( ke != null && ke.key == "Enter" && !busy ) locate();
			if( ke != null && ke.key == "Escape" && job != null ) { ev.preventDefault(); cancelJob(); }
		});
	}

	function profileFormHtml() : String {
		var h = new StringBuf();
		for( g in PROFILE_GROUPS ) {
			h.add('<div class="g-pgroup">');
			if( g.toggle != null )
				h.add('<label class="g-ptoggle"><input type="checkbox" data-path="${g.toggle}"/>${g.title}</label>');
			else
				h.add('<div class="g-ptitle">${g.title}</div>');
			h.add('<div class="g-pparams">');
			for( f in g.fields ) {
				if( f.bool == true )
					h.add('<label class="g-prow g-prow-bool"><input type="checkbox" data-path="${f.path}"/>${f.label}</label>');
				else
					h.add('<div class="g-prow"><span>${f.label}</span><input type="number" step="any" data-path="${f.path}"/></div>');
			}
			h.add('</div></div>');
		}
		return h.toString();
	}

	// ── Current project ───────────────────────────────────────────────────

	/** The Editor page, unless another page replaced it (its dispose is deferred). **/
	function activeEditor() : Null<Editor> {
		var editor = Editor.ME;
		if( editor == null || editor.destroyed || editor.project == null ) return null;
		return editor;
	}

	function currentProjectPath() : Null<String> {
		var editor = activeEditor();
		if( editor == null ) return null;
		var fp = editor.project.filePath;
		if( fp == null ) return null;
		return fp.full;
	}

	/** Called by App.loadPage() after every page change (Home, Editor…). **/
	public function onPageLoaded() {
		// The new Editor emitted ProjectSelected in its constructor, before this
		// listener exists; later in-place project swaps and saves come through it.
		var editor = activeEditor();
		if( editor != null )
			editor.ge.addGlobalListener(onEditorEvent);
		else
			stopPolling(); // project closed: the request still answers, but nobody watches it
		onProjectChanged();
		clearRoute();
		scheduleRouteFetch();
		clearDifficulty();
		scheduleDifficultyFetch();
	}

	function onEditorEvent(e:GlobalEvent) {
		switch e {
			case ProjectSelected:
				onProjectChanged();
				refreshLevels();
				if( routeFromResponse && samePath(routePath, currentProjectPath()) ) {
					routeFromResponse = false; // reload after a generate / edit / undo: its route is current
					drawRoute();
				}
				else {
					clearRoute();
					scheduleRouteFetch();
				}
				if( difficultyFromResponse && samePath(difficultyPath, currentProjectPath()) )
					difficultyFromResponse = false;
				else {
					clearDifficulty();
					scheduleDifficultyFetch();
				}

			case ProjectSaved:
				onProjectChanged();
				scheduleRouteFetch();
				scheduleDifficultyFetch();

			case LevelSelected(l):
				refreshLevels();
				refreshSections();
				drawOverlay();
				if( route != null && route.level_iid == l.iid )
					drawRoute();
				else {
					clearRoute();
					scheduleRouteFetch();
				}
				scheduleDifficultyFetch(); // the sections of the new level

			case ViewportChanged(true):
				drawRoute(); // line widths follow the zoom

			// Hand edits
			case LayerInstanceEditedByTool(_), LayerInstanceChangedGlobally(_),
				LayerInstancesRestoredFromHistory(_), LevelRestoredFromHistory(_),
				EntityInstanceAdded(_), EntityInstanceRemoved(_), EntityInstanceChanged(_),
				EntityFieldInstanceChanged(_):
				scheduleRouteFetch();
				scheduleDifficultyFetch();

			case _:
		}
	}

	function onProjectChanged() {
		refreshFileRow();
		if( currentProjectPath() != profilePath || profile == null )
			loadProfile();
		refreshEdit();
	}

	function refreshFileRow() {
		var path = currentProjectPath();
		if( path != null ) {
			var name = path.split("/").pop();
			jFile.html('<span class="g-file-icon">&#x1F4C4;</span><span class="g-file-name">${esc(name)}</span>');
			jFile.attr("title", path);
			jFile.removeClass("g-file-none");
		} else {
			jFile.html('<span class="g-file-label">No project open — open a .ldtk file first</span>');
			jFile.removeAttr("title");
			jFile.addClass("g-file-none");
		}
	}

	// ── Persist / restore ─────────────────────────────────────────────────

	function saveStr(k:String, v:String) js.Browser.window.localStorage.setItem(k, v);
	function loadStr(k:String) : Null<String> return js.Browser.window.localStorage.getItem(k);

	function restoreState() {
		var provider = loadStr(PROVIDER_KEY);
		jProvider.val( provider != null && PROVIDERS.contains(provider) ? provider : PROVIDERS[0] );
		var model = loadStr(MODEL_KEY);
		if( model != null ) jModel.val(model);
		setProfileOpen( loadStr(PROFILE_KEY) == "1" );
		setMemoryOpen( loadStr(MEMORY_KEY) == "1" );
		var mode = loadStr(MODE_KEY);
		setEditMode( mode != null && EDIT_MODES.filter( m->m.id == mode ).length > 0 ? mode : EDIT_MODES[0].id );
		setEditOpen( loadStr(EDIT_KEY) != "0" );
		jRouteOn.prop("checked", loadStr(ROUTE_KEY) != "0");
		refreshFileRow();
	}

	function restoreHistory() {
		var saved = loadStr(HIST_KEY);
		if( saved != null ) {
			jHistory.html(saved);
			jHistory.scrollTop( jHistory.prop("scrollHeight") );
		}
	}

	function persistHistory() saveStr(HIST_KEY, jHistory.html());

	function clearHistory() {
		jHistory.empty();
		js.Browser.window.localStorage.removeItem(HIST_KEY);
	}

	// ── Server ────────────────────────────────────────────────────────────

	/** JSON request (a String body is sent as it is); `res` is null when the response is not JSON. **/
	function request(method:String, route:String, body:Null<Dynamic>,
	                 onDone:(status:Int, res:Dynamic)->Void, onOffline:Void->Void) {
		var xhr = new js.html.XMLHttpRequest();
		xhr.open(method, SERVER + route);
		if( body != null ) xhr.setRequestHeader("Content-Type", "application/json");
		xhr.onload = function(_) {
			var res : Dynamic = null;
			try { res = haxe.Json.parse(xhr.responseText); } catch(_) {}
			onDone(xhr.status, res);
		};
		xhr.onerror = function(_) onOffline();
		xhr.send( body == null ? null : Std.isOfType(body, String) ? body : haxe.Json.stringify(body) );
	}

	function loadProviders() {
		request("GET", "/providers", null, (status, res)-> {
			if( status != 200 || res == null ) return;
			var list : Array<Dynamic> = res.providers;
			for( p in list )
				defaultModels.set(p.name, p.default_model);
			updateModelPlaceholder();
		}, ()->{} );
	}

	function updateModelPlaceholder() {
		var model = defaultModels.get( jProvider.val() );
		jModel.attr("placeholder", model != null ? 'default: $model' : "default model");
	}

	// ── UI helpers ────────────────────────────────────────────────────────

	function toggleCollapse() {
		collapsed = !collapsed;
		if( !collapsed ) refreshFileRow();
		jRoot.toggleClass("collapsed", collapsed);
		jToggle.toggleClass("open", !collapsed);
	}

	function setStatus(s:String) jStatus.text(s);

	static function esc(s:Dynamic) : String {
		return s == null ? "" : StringTools.htmlEscape(Std.string(s), true);
	}

	function appendMsg(cls:String, html:String) {
		var el = new J('<div class="g-msg g-msg-${cls}"></div>');
		el.html(html);
		jHistory.append(el);
		jHistory.scrollTop( jHistory.prop("scrollHeight") );
		persistHistory();
	}

	/**
		`editing`: the edit panel started the request (its button shows the progress).
		With a running job, that button turns into Cancel.
	**/
	function setBusy(b:Bool, editing=false) {
		busy = b;
		var cancel = b && job != null;
		jBtn.prop("disabled", b && (editing || !cancel));
		jBtn.toggleClass("g-cancel", cancel && !editing);
		jBtn.html( b && !editing ? (cancel ? "&#x25A0;&nbsp; Cancel" : "Generating…") : "&#x25B6;&nbsp; Generate" );
		jEditBtn.prop("disabled", b && !(editing && cancel));
		jEditBtn.toggleClass("g-cancel", cancel && editing);
		jLocated.find("button").prop("disabled", b);
		if( b && editing ) {
			jEditBtn.show(); // also while "Apply here" runs (it hides the button)
			jEditBtn.html( cancel ? "&#x25A0;&nbsp; Cancel" : "Working…" );
		}
		else
			refreshEditButton();
		refreshUndo();
	}

	// ── Design memory ─────────────────────────────────────────────────────

	function setMemoryOpen(open:Bool) {
		jMemHead.toggleClass("open", open);
		jMem.toggle(open);
		saveStr(MEMORY_KEY, open ? "1" : "0");
		if( open ) refreshMemory();
	}

	function refreshMemory() {
		if( !jMemHead.hasClass("open") ) return;
		request("GET", "/memory", null, (status, res)-> {
			if( status == 200 && res != null ) { memory = res; renderMemory(); }
			else jMemNote.text("error");
		}, ()-> jMemNote.text("server offline") );
	}

	function putMemory(body:Dynamic) {
		request("PUT", "/memory", body, (status, res)-> {
			if( status == 200 && res != null ) { memory = res; renderMemory(); }
			else jMemNote.text("error: " + errorText(status, res));
		}, ()-> jMemNote.text("server offline") );
	}

	function renderMemory() {
		var m : Dynamic = memory;
		var enabled = m.enabled != false;
		var rules : Array<Dynamic> = m.rules != null ? m.rules : [];
		var stats : Dynamic = m.stats != null ? m.stats : {};
		var h = '<label class="g-ptoggle"><input type="checkbox" id="g-mem-on" ${enabled ? "checked" : ""}/>Learn from my edits</label>';
		h += '<div class="g-mem-rules">';
		if( rules.length == 0 )
			h += '<div class="g-mem-none">No rules yet</div>';
		for( r in rules ) {
			var on = r.enabled != false;
			var conf : Null<Float> = r.confidence;
			h += '<div class="g-mem-rule${on ? "" : " g-off"}" data-id="${esc(r.id)}">' +
				'<input type="checkbox" class="g-mem-en" ${on ? "checked" : ""} title="Use this rule"/>' +
				'<input type="text" class="g-mem-text" value="${esc(r.text)}"/>' +
				'<span class="g-mem-badge" title="source">${esc(r.source)}</span>' +
				'<span class="g-mem-conf" title="confidence">${conf != null ? Math.round(conf*100) + "%" : ""}</span>' +
				'<button class="g-x g-mem-del" title="Delete rule">&times;</button></div>';
		}
		h += '</div>';
		var st = [];
		for( k in MEMORY_STATS ) {
			var v : Dynamic = Reflect.field(stats, k);
			if( v == null ) continue;
			var vs = memStatStr(v);
			if( vs == "" ) continue;
			st.push('<div class="g-prow"><span>${esc(k)}</span><b>${esc(vs)}</b></div>');
		}
		h += '<div class="g-mem-stats">${st.join("")}</div>';
		h += '<div class="g-prow"><span>events</span><b id="g-mem-events">${m.event_count != null ? m.event_count : 0}</b></div>';
		h += '<div class="g-mem-btns"><button class="g-small-btn" id="g-mem-scan">Scan now</button>' +
			'<button class="g-small-btn" id="g-mem-reset">Reset</button></div>';
		jMem.html(h);
		jMemNote.text( enabled ? rules.length + " rule" + (rules.length == 1 ? "" : "s") : "off" );
	}

	/** Compact text for a stat: numbers rounded, objects as `key value` pairs without nulls. **/
	static function memStatStr(v:Dynamic) : String {
		if( v == null ) return "";
		if( Std.isOfType(v, Float) ) return Std.string( Math.round((v:Float)*100)/100 );
		if( Std.isOfType(v, Array) ) return (v:Array<Dynamic>).map( memStatStr ).join(", ");
		if( Std.isOfType(v, String) || Std.isOfType(v, Bool) ) return Std.string(v);
		var parts = [];
		for( k in Reflect.fields(v) ) {
			var sub = memStatStr( Reflect.field(v, k) );
			if( sub != "" ) parts.push('$k $sub');
		}
		return parts.join(", ");
	}

	function bindMemory() {
		jMem.on("change", "#g-mem-on", function(ev:js.jquery.Event) putMemory({ enabled: new J(ev.target).prop("checked") }) );
		jMem.on("change", ".g-mem-en", function(ev:js.jquery.Event) {
			var j = new J(ev.target);
			putMemory({ rules: [{ id: j.closest(".g-mem-rule").attr("data-id"), enabled: j.prop("checked") }] });
		});
		jMem.on("change", ".g-mem-text", function(ev:js.jquery.Event) {
			var j = new J(ev.target);
			putMemory({ rules: [{ id: j.closest(".g-mem-rule").attr("data-id"), text: StringTools.trim(j.val()) }] });
		});
		jMem.on("click", ".g-mem-del", function(ev:js.jquery.Event) {
			var id = new J(ev.target).closest(".g-mem-rule").attr("data-id");
			putMemory({ delete: [id] });
		});
		jMem.on("click", "#g-mem-scan", function(_) {
			var path = currentProjectPath();
			if( path == null ) { jMemNote.text("no project"); return; }
			jMemNote.text("scanning…");
			request("POST", "/memory/scan", { path: path }, (status, res)-> {
				if( status != 200 ) jMemNote.text("error: " + errorText(status, res));
				else refreshMemory();
			}, ()-> jMemNote.text("server offline") );
		});
		jMem.on("click", "#g-mem-reset", function(_) {
			new ui.modal.dialog.Confirm(null, L.untranslated("Reset all design memory (learned rules and stats)?"), true, ()-> {
				request("DELETE", "/memory", null, (status, res)-> {
					if( status == 200 ) refreshMemory();
					else jMemNote.text("error: " + errorText(status, res));
				}, ()-> jMemNote.text("server offline") );
			});
		});
	}

	// ── Game Profile ──────────────────────────────────────────────────────

	function setProfileOpen(open:Bool) {
		jProfHead.toggleClass("open", open);
		jProf.toggle(open);
		saveStr(PROFILE_KEY, open ? "1" : "0");
		if( open && profile == null && currentProjectPath() != null )
			loadProfile();
	}

	static function getPath(o:Dynamic, path:String) : Dynamic {
		for( k in path.split(".") ) {
			if( o == null ) return null;
			o = Reflect.field(o, k);
		}
		return o;
	}

	static function setPath(o:Dynamic, path:String, v:Dynamic) {
		var keys = path.split(".");
		var last = keys.pop();
		for( k in keys ) o = Reflect.field(o, k);
		Reflect.setField(o, last, v);
	}

	function loadProfile() {
		var path = currentProjectPath();
		profilePath = path;
		profile = null;
		clearProfileErrors();
		jProf.toggleClass("g-off", true);
		if( path == null ) {
			jProfNote.text("no project");
			return;
		}
		jProfNote.text("loading…");
		request("GET", "/profile?path=" + StringTools.urlEncode(path), null, (status, res)-> {
			if( path != profilePath ) return; // another project was opened meanwhile
			if( status == 200 && res != null ) {
				profile = res;
				fillProfile();
				jProfNote.text( res.name != null ? res.name : "" );
			}
			else {
				jProfNote.text("error");
				showProfileErrors(status, res);
			}
		}, ()-> if( path == profilePath ) jProfNote.text("server offline") );
	}

	function fillProfile() {
		jProf.find("input[data-path]").each( (_, el)-> {
			var jIn = new J(el);
			var v = getPath(profile, jIn.attr("data-path"));
			if( jIn.attr("type") == "checkbox" )
				jIn.prop("checked", v == true);
			else
				jIn.val( v == null ? "" : Std.string(v) );
		});
		jProf.toggleClass("g-off", false);
		updateAbilityToggles();
	}

	function updateAbilityToggles() {
		jProf.find(".g-pgroup").each( (_, el)-> {
			var jGroup = new J(el);
			var jToggle = jGroup.find(".g-ptoggle input");
			if( jToggle.length > 0 )
				jGroup.find(".g-pparams").toggleClass("g-off", !jToggle.prop("checked"));
		});
	}

	function saveProfile() {
		var path = profilePath;
		if( profile == null || path == null || path != currentProjectPath() ) return;

		// Edit a copy of the loaded profile so fields the panel doesn't show survive.
		var body : Dynamic = haxe.Json.parse( haxe.Json.stringify(profile) );
		jProf.find("input[data-path]").each( (_, el)-> {
			var jIn = new J(el);
			var v : Dynamic;
			if( jIn.attr("type") == "checkbox" )
				v = jIn.prop("checked") == true;
			else {
				var raw = StringTools.trim(jIn.val());
				var f = Std.parseFloat(raw);
				v = raw.length == 0 ? null : Math.isNaN(f) ? raw : f; // bad values: the server reports them
			}
			setPath(body, jIn.attr("data-path"), v);
		});

		clearProfileErrors();
		jProfNote.text("saving…");
		request("PUT", "/profile?path=" + StringTools.urlEncode(path), body, (status, res)-> {
			if( path != profilePath ) return;
			if( status == 200 && res != null ) {
				profile = res;
				fillProfile();
				jProfNote.text("saved");
			}
			else {
				jProfNote.text("not saved");
				showProfileErrors(status, res);
			}
		}, ()-> jProfNote.text("server offline") );
	}

	function clearProfileErrors() {
		jProf.find(".g-invalid").removeClass("g-invalid");
		jProf.find(".g-perr").remove();
		jProfErr.empty();
	}

	/** 422 errors go next to their field; anything else under the panel. **/
	function showProfileErrors(status:Int, res:Dynamic) {
		var general = [];
		var detail : Dynamic = res != null ? res.detail : null;
		if( Std.isOfType(detail, Array) ) {
			var errors : Array<Dynamic> = detail;
			for( e in errors ) {
				var loc : Array<Dynamic> = e.loc != null ? e.loc : [];
				var field = loc.filter( k->k != "body" && k != "query" ).map( k->Std.string(k) ).join(".");
				var jIn = jProf.find('input[data-path="$field"]');
				if( jIn.length > 0 ) {
					jIn.addClass("g-invalid");
					jIn.closest(".g-prow, .g-ptoggle").after('<div class="g-perr">${esc(e.msg)}</div>');
				}
				else
					general.push( (field.length > 0 ? field + ": " : "") + e.msg );
			}
		}
		else
			general.push( detail != null ? Std.string(detail) : 'Server returned HTTP $status.' );
		jProfErr.html( general.map( m->'<div>${esc(m)}</div>' ).join("") );
	}

	// ── Edit (regional editing + undo) ────────────────────────────────────

	function setEditOpen(open:Bool) {
		jEditHead.toggleClass("open", open);
		jEdit.toggle(open);
		saveStr(EDIT_KEY, open ? "1" : "0");
		if( !open && activeEditor() != null )
			activeEditor().clearSpecialTool();
		drawOverlay();
	}

	function setEditMode(mode:String) {
		editMode = mode;
		saveStr(MODE_KEY, mode);
		jEdit.find(".g-mode-btn").each( (_, el)-> {
			var jBtn = new J(el);
			jBtn.toggleClass("active", jBtn.attr("data-mode") == mode);
		});
		jEdit.find("[data-modes]").each( (_, el)-> {
			var jEl = new J(el);
			jEl.toggle( jEl.attr("data-modes").split(" ").contains(mode) );
		});
		if( mode != "describe" )
			located = null;
		refreshLocated();
		refreshTarget();
		refreshEditButton();
		drawOverlay();
	}

	/** Re-reads the level after a project change, reload or save. **/
	function refreshEdit() {
		var path = currentProjectPath();
		if( path != editPath ) {
			// Another project: its selection doesn't apply anymore
			editPath = path;
			area = null;
			located = null;
			snapshots = [];
			refreshLocated();
		}
		refreshSections();
		refreshTarget();
		refreshHistory();
		drawOverlay();
	}

	function refreshEditButton() {
		var m = EDIT_MODES.filter( m->m.id == editMode )[0];
		jEditBtn.text( m != null ? m.action : "Apply" );
		jEditBtn.toggle( located == null );
		jEditPrompt.attr("placeholder", editMode == "entities"
			? "What should change? eg. make the bats stronger"
			: "What should be there? eg. a spike pit with two floating platforms");
	}

	/** Grid used for tile coordinates: the IntGrid layer, as in the exported level. **/
	function gridLayer() : Null<data.inst.LayerInstance> {
		var editor = activeEditor();
		if( editor == null || editor.curLevel == null ) return null;
		for( li in editor.curLevel.layerInstances )
			if( li.def.type == IntGrid )
				return li;
		return editor.curLayerInstance;
	}

	static function rectStr(r:GldtkRect) : String {
		return '${r.w}×${r.h} at (${r.col}, ${r.row})';
	}

	// Sections

	function refreshSections() {
		var prev = jSection.val();
		sections = [];
		var editor = activeEditor();
		if( editor != null && editor.curLevel != null )
			for( fi in editor.curLevel.fieldInstances )
				if( fi.def.identifier == "gldtk_sections" && !fi.valueIsNull(0) ) {
					try {
						var arr : Array<Dynamic> = haxe.Json.parse( fi.getString(0) );
						if( Std.isOfType(arr, Array) ) sections = arr;
					}
					catch(_) {}
				}

		if( sections.length == 0 )
			jSection.html('<option value="">No GLDtk sections in this level</option>');
		else
			jSection.html( sections.map( s->'<option value="${esc(s.id)}">${esc(s.name != null ? s.name : s.id)}' +
				( s.difficulty != null ? ' · ${esc(s.difficulty)}' : "" ) +
				( s.structure != null ? ' · ${esc(s.structure)}' : "" ) + '</option>' ).join("") );
		if( prev != null && sections.filter( s->s.id == prev ).length > 0 )
			jSection.val(prev);
		jSection.prop("disabled", sections.length == 0);
		jStructure.prop("disabled", sections.length == 0);
	}

	function selectedSection() : Null<Dynamic> {
		var id = jSection.val();
		for( s in sections )
			if( s.id == id ) return s;
		return null;
	}

	/** The section's band; old files only store the columns of horizontal sections. **/
	function selectedSectionRect() : Null<GldtkRect> return sectionRect( selectedSection() );

	function sectionRect(s:Null<Dynamic>) : Null<GldtkRect> {
		var li = gridLayer();
		if( s == null || li == null ) return null;
		var c0 : Int = s.col_start != null ? s.col_start : 0;
		var c1 : Int = s.col_end   != null ? s.col_end   : li.cWid-1;
		var r0 : Int = s.row_start != null ? s.row_start : 0;
		var r1 : Int = s.row_end   != null ? s.row_end   : li.cHei-1;
		return { col: c0, row: r0, w: c1-c0+1, h: r1-r0+1 };
	}

	// Area selection and entity target

	function startAreaSelection() {
		var editor = activeEditor();
		var li = gridLayer();
		if( editor == null || li == null ) {
			jEditNote.text("open a level first");
			return;
		}
		if( editor.isSpecialToolActive(tool.GldtkAreaTool) ) {
			editor.clearSpecialTool(); // second click cancels
			return;
		}
		var t = new tool.GldtkAreaTool(li);
		t.onChange = r-> { dragArea = r; drawOverlay(); };
		t.onSelect = r-> { area = r; dragArea = null; refreshTarget(); drawOverlay(); };
		t.onEnd = ()-> { dragArea = null; jAreaBtn.removeClass("active"); drawOverlay(); };
		editor.setSpecialTool(t);
		jAreaBtn.addClass("active");
		jEditNote.text("drag on the level");
	}

	/** iids of the entities currently selected in LDtk. **/
	function selectedEntityIids() : Array<String> {
		var editor = activeEditor();
		if( editor == null ) return [];
		var iids = [];
		for( e in @:privateAccess editor.selectionTool.group.allElements() )
			if( e != null )
				switch e {
					case Entity(_, ei): iids.push(ei.iid);
					case _:
				}
		return iids;
	}

	function refreshTarget() {
		var text = switch editMode {
			case "entities":
				var n = selectedEntityIids().length;
				n > 0 ? '$n selected entit${n > 1 ? "ies" : "y"}' : area != null ? "area " + rectStr(area) : "whole level";
			case _:
				area != null ? rectStr(area) : "no area selected";
		}
		jTarget.text(text);
		jTarget.toggleClass("g-none", editMode == "region" && area == null);
		jEditNote.text( switch editMode {
			case "section": var r = selectedSectionRect(); r != null ? rectStr(r) : "";
			case _: "";
		});
	}

	// Canvas overlay

	/** Overlay graphics in the level render (level pixel coords), recreated with the Editor. **/
	function getOverlay() : Null<h2d.Graphics> {
		var editor = activeEditor();
		if( editor == null || editor.levelRender == null || editor.levelRender.root == null ) return null;
		var root = editor.levelRender.root;
		if( overlay == null || overlay.parent != root ) {
			if( overlay != null ) overlay.remove();
			overlay = new h2d.Graphics();
			root.add(overlay, Const.DP_TOP);
		}
		return overlay;
	}

	function drawOverlay() {
		var g = getOverlay();
		if( g == null ) return;
		g.clear();
		var li = gridLayer();
		if( li == null || !jEditHead.hasClass("open") ) return;

		var gs = li.def.gridSize;
		function draw(r:Null<GldtkRect>, col:UInt) {
			if( r == null ) return;
			g.lineStyle(2, col, 0.9);
			g.beginFill(col, 0.18);
			g.drawRect(r.col*gs, r.row*gs, r.w*gs, r.h*gs);
			g.endFill();
		}
		switch editMode {
			case "region", "entities": draw( dragArea != null ? dragArea : area, AREA_COLOR );
			case "section": draw( selectedSectionRect(), SECTION_COLOR );
			case "describe": draw( located != null ? located.rect : null, LOCATE_COLOR );
			case _:
		}
		App.ME.requestCpu();
	}

	function bleepRect(r:Null<GldtkRect>, col:UInt) {
		var editor = activeEditor();
		var li = gridLayer();
		if( r == null || editor == null || li == null ) return;
		var gs = li.def.gridSize;
		editor.levelRender.bleepLevelRectPx(r.col*gs, r.row*gs, r.w*gs, r.h*gs, col, 2);
	}

	// Requests

	function editBase(path:String) : Dynamic {
		var payload : Dynamic = {
			path:     path,
			provider: jProvider.val(),
			seed:     Std.int( Math.random() * 100000 ),
		};
		var model = StringTools.trim( jModel.val() );
		if( model.length > 0 )
			Reflect.setField(payload, "model", model);
		var lv = curLevelIid();
		if( lv != null )
			payload.level = lv;
		return payload;
	}

	/** Path for an edit, or null (with a message) when no project is open. **/
	function editTargetPath() : Null<String> {
		var path = currentProjectPath();
		refreshFileRow();
		if( path == null )
			appendMsg("err", "Open a .ldtk project in LDtk first.");
		return path;
	}

	/** Edits read the file on disk (it is the source of truth), so unsaved hand edits are saved first. **/
	function saveFirst(then:Void->Void) {
		var editor = activeEditor();
		if( editor == null || !editor.needSaving ) {
			then();
			return;
		}
		setStatus("saving…");
		editor.onSave(false, null, ()-> {
			if( editor.needSaving ) {
				appendMsg("err", "Save your changes in LDtk first: the edit works on the saved file.");
				setStatus("error");
			}
			else
				then();
		});
	}

	function editPrompt() : Null<String> {
		var prompt = StringTools.trim( jEditPrompt.val() );
		if( prompt.length == 0 ) {
			jEditNote.text("describe the change first");
			jEditPrompt.focus();
			return null;
		}
		return prompt;
	}

	function applyEdit() {
		if( editMode == "describe" ) {
			locate();
			return;
		}
		var prompt = editPrompt();
		if( prompt == null ) return;
		var path = editTargetPath();
		if( path == null ) return;

		var payload = editBase(path);
		payload.prompt = prompt;
		switch editMode {
			case "region":
				if( area == null ) {
					jEditNote.text("select an area first");
					return;
				}
				payload.rect = area;
				postEdit("/edit/region", payload, 'Region ${rectStr(area)}', prompt);

			case "section":
				var s = selectedSection();
				if( s == null ) {
					jEditNote.text("no section to edit");
					return;
				}
				payload.section_id = s.id;
				postEdit("/edit/section", payload, 'Section ${s.name != null ? s.name : s.id}', prompt);

			case "entities":
				var iids = selectedEntityIids();
				var target : String;
				if( iids.length > 0 ) {
					payload.entity_iids = iids;
					target = '${iids.length} selected';
				}
				else if( area != null ) {
					payload.rect = area;
					target = rectStr(area);
				}
				else
					target = "whole level";
				postEdit("/edit/entities", payload, 'Entities · $target', prompt);

			case _:
		}
	}

	function applyStructure() {
		var type : String = jStructure.val();
		jStructure.val("");
		if( type == null || type == "" ) return;
		var s = selectedSection();
		if( s == null ) {
			jEditNote.text("no section to edit");
			return;
		}
		var path = editTargetPath();
		if( path == null ) return;
		var prompt = "make this a " + type;
		var payload = editBase(path);
		payload.prompt = prompt;
		payload.section_id = s.id;
		payload.structure = type;
		postEdit("/edit/section", payload, 'Section ${s.name != null ? s.name : s.id}', prompt);
	}

	function postEdit(route:String, payload:Dynamic, label:String, prompt:String, ?onDone:Void->Void) {
		appendMsg("user", '<span class="g-meta">&#x270E; ${esc(label)}</span>${esc(prompt)}');
		saveFirst( ()-> sendEdit(route, payload, label, onDone) );
	}

	function sendEdit(route:String, payload:Dynamic, label:String, ?onDone:Void->Void) {
		payload.job_id = startJob();
		setBusy(true, true);
		setStatus("editing…");
		var path : String = payload.path;
		request("POST", route, payload, (status, res)-> {
			var cancelling = endJob();
			setBusy(false);
			if( status == 200 && res != null && res.cancelled == true ) {
				onCancelled();
				return;
			}
			if( status != 200 || res == null || res.success == false ) {
				appendMsg("err", esc(errorText(status, res)) + '<span class="g-meta g-unchanged">The level was not changed.</span>');
				setStatus("error");
				return;
			}
			if( onDone != null ) onDone();
			if( cancelling ) noteTooLate();
			var e : Dynamic = res.edit;
			var region : Dynamic = e != null ? e.region : null;
			var header = '<span class="g-meta g-edit-meta">&#x270E; ${esc(label)}' +
				( region != null && region.w != null && label.indexOf(rectStr(region)) < 0 ? ' · ${esc(rectStr(region))}' : "" ) + '</span>';
			onSuccess(res, path, header);
		}, ()-> {
			endJob();
			setBusy(false);
			appendMsg("err", "Cannot reach GLDtk server — is <code>python server.py</code> running?");
			setStatus("offline");
		});
	}

	/** Error message from a failed response: `error`, FastAPI's `detail`, or the HTTP status. **/
	static function errorText(status:Int, res:Dynamic) : String {
		if( res == null )
			return status == 200 ? "Parse error — invalid JSON from server." : 'Server returned HTTP $status.';
		if( res.error != null )
			return Std.string(res.error);
		var detail : Dynamic = res.detail;
		if( Std.isOfType(detail, Array) ) {
			var errors : Array<Dynamic> = detail;
			return errors.map( e->e.msg != null ? Std.string(e.msg) : Std.string(e) ).join("; ");
		}
		if( detail != null )
			return Std.string(detail);
		return status == 200 ? "Unknown error" : 'Server returned HTTP $status.';
	}

	// Describe: locate, then confirm

	function locate() {
		var text = StringTools.trim( jLocText.val() );
		if( text.length == 0 ) {
			jEditNote.text("describe a location first");
			jLocText.focus();
			return;
		}
		var path = editTargetPath();
		if( path == null ) return;

		var payload = editBase(path);
		Reflect.deleteField(payload, "seed");
		payload.text = text;

		appendMsg("user", '<span class="g-meta">&#x1F4CD; Locate</span>${esc(text)}');
		saveFirst( ()-> sendLocate(path, payload) );
	}

	function sendLocate(path:String, payload:Dynamic) {
		payload.job_id = startJob();
		setBusy(true, true);
		setStatus("locating…");
		request("POST", "/edit/locate", payload, (status, res)-> {
			endJob();
			setBusy(false);
			if( status == 200 && res != null && res.cancelled == true ) {
				onCancelled();
				return;
			}
			var r : Dynamic = res != null ? res.rect : null;
			if( status != 200 || res == null || res.success == false || r == null || r.w == null ) {
				appendMsg("err", esc(errorText(status, res)));
				setStatus("error");
				return;
			}
			if( path != currentProjectPath() ) return;
			located = {
				rect: { col: r.col, row: r.row, w: r.w, h: r.h },
				explanation: res.explanation != null ? res.explanation : "",
			};
			appendMsg("ai", '<span class="g-meta">&#x1F4CD; ${esc(rectStr(located.rect))}</span>${esc(located.explanation)}');
			setStatus("ready");
			refreshLocated();
			refreshEditButton();
			drawOverlay();
			bleepRect(located.rect, LOCATE_COLOR);
		}, ()-> {
			endJob();
			setBusy(false);
			appendMsg("err", "Cannot reach GLDtk server — is <code>python server.py</code> running?");
			setStatus("offline");
		});
	}

	function refreshLocated() {
		jLocated.empty();
		if( located == null ) return;
		jLocated.html(
			'<div class="g-located-text"><b>${esc(rectStr(located.rect))}</b> ${esc(located.explanation)}</div>' +
			'<div class="g-field"><button class="g-loc-apply">Apply here</button><button class="g-loc-cancel gray">Cancel</button></div>'
		);
		jLocated.find(".g-loc-apply").click( _-> if( !busy ) applyLocated() );
		jLocated.find(".g-loc-cancel").click( _-> cancelLocated() );
	}

	function applyLocated() {
		if( located == null ) return;
		var prompt = editPrompt();
		if( prompt == null ) return;
		var path = editTargetPath();
		if( path == null ) return;
		var payload = editBase(path);
		payload.rect = located.rect;
		payload.prompt = prompt;
		postEdit("/edit/region", payload, 'Region ${rectStr(located.rect)}', prompt, cancelLocated);
	}

	function cancelLocated() {
		located = null;
		refreshLocated();
		refreshEditButton();
		drawOverlay();
	}

	// History and undo

	function refreshHistory() {
		var path = currentProjectPath();
		if( path == null ) {
			snapshots = [];
			refreshUndo();
			return;
		}
		request("GET", "/history?path=" + StringTools.urlEncode(path), null, (status, res)-> {
			if( path != currentProjectPath() ) return;
			var list : Array<Dynamic> = status == 200 && res != null && res.snapshots != null ? res.snapshots : [];
			// Newest first, whatever order the server uses (timestamps sort as text)
			list.sort( (a, b)-> Reflect.compare(Std.string(b.timestamp), Std.string(a.timestamp)) );
			snapshots = list;
			refreshUndo();
		}, ()-> {
			snapshots = [];
			refreshUndo();
		});
	}

	function refreshUndo() {
		var n = snapshots.length;
		jUndo.prop("disabled", busy || n == 0);
		jUndo.html('&#x21B6; Undo last GLDtk edit' + ( n > 0 ? ' <span class="g-count">$n</span>' : "" ));
		jUndo.attr("title", n > 0
			? 'Restore the file as it was before: ${snapshots[0].label != null ? snapshots[0].label : snapshots[0].timestamp}'
			: "No GLDtk snapshot for this file");
	}

	function undo() {
		var path = editTargetPath();
		if( path == null || snapshots.length == 0 ) return;
		var editor = activeEditor();
		if( editor != null && editor.needSaving )
			new ui.modal.dialog.Confirm(null, L.untranslated("Undo restores the file from before the last GLDtk edit. Your unsaved changes will be lost."), true, sendUndo.bind(path));
		else
			sendUndo(path);
	}

	function sendUndo(path:String) {
		var newest = snapshots[0];
		setBusy(true, true);
		setStatus("undoing…");
		var undoBody : Dynamic = { path: path };
		var lv = curLevelIid();
		if( lv != null ) undoBody.level = lv;
		request("POST", "/undo", undoBody, (status, res)-> {
			setBusy(false);
			if( status != 200 || res == null || res.success == false ) {
				appendMsg("err", esc(errorText(status, res)));
				setStatus("error");
				refreshHistory();
				return;
			}
			takeLevels(res, path);
			takeRoute(res.route, path);
			takeDifficulty(res.difficulty, path);
			refreshMemory();
			var label = newest.label != null ? newest.label : newest.timestamp;
			var remaining : Null<Int> = res.remaining;
			appendMsg("ai",
				'<span class="g-meta g-edit-meta">&#x21B6; Undo</span>' +
				'Restored the file from before: ${esc(label)}' +
				'<span class="g-ok">&#x2713; ${remaining != null ? remaining + " older snapshot" + (remaining == 1 ? "" : "s") + " left" : "Restored"}</span>'
			);
			setStatus("reloading…");
			haxe.Timer.delay( ()-> reloadGeneratedProject(path), 400 );
		}, ()-> {
			setBusy(false);
			appendMsg("err", "Cannot reach GLDtk server — is <code>python server.py</code> running?");
			setStatus("offline");
		});
	}

	// ── Golden route (v3 Part 13) ─────────────────────────────────────────

	/** The route of a generate / edit / undo response, for the file about to be reloaded. **/
	function takeRoute(r:Null<Dynamic>, path:String) {
		if( r == null || !samePath(path, currentProjectPath()) ) return; // not reloaded: ProjectSelected refetches
		setRoute(r, path);
		routeFromResponse = true;
	}

	function setRoute(r:Dynamic, path:String) {
		cancelRouteFetch();
		routeSeq++;
		route = r;
		routePath = path;
		refreshRouteSummary();
		drawRoute();
	}

	function clearRoute() {
		cancelRouteFetch();
		routeSeq++;
		route = null;
		routePath = null;
		routeFromResponse = false;
		refreshRouteSummary();
		routeOverlay.clear();
	}

	function cancelRouteFetch() {
		if( routeTimer != null ) {
			routeTimer.stop();
			routeTimer = null;
		}
	}

	/** Refetches the route a little after the last change. **/
	function scheduleRouteFetch() {
		cancelRouteFetch();
		if( currentProjectPath() == null ) return;
		routeTimer = haxe.Timer.delay( ()-> { routeTimer = null; fetchRoute(); }, ROUTE_DEBOUNCE_MS );
	}

	/** GET /route reads the saved file; with unsaved changes, POST /route sends the project as it is in LDtk. **/
	function fetchRoute() {
		var editor = activeEditor();
		var path = currentProjectPath();
		if( editor == null || path == null ) return;
		var seq = ++routeSeq;
		if( route == null )
			jRouteSum.removeClass("g-route-bad").text("Route: checking…");

		function onDone(status:Int, res:Dynamic) {
			if( seq != routeSeq || !samePath(path, currentProjectPath()) ) return;
			setRoute( status == 200 && res != null ? res : { success: false, error: errorText(status, res) }, path );
		}
		function onOffline() {
			if( seq != routeSeq ) return;
			route = null;
			routeOverlay.clear();
			jRouteSum.removeClass("g-route-bad").text("Route: server offline");
		}
		if( editor.needSaving ) {
			var lv = curLevelIid();
			var body = '{"path":${haxe.Json.stringify(path)},' + ( lv != null ? '"level":${haxe.Json.stringify(lv)},' : "" ) + '"project":${dn.data.JsonPretty.stringify(editor.project.toJson(), Minified)}}';
			request("POST", "/route", body, onDone, onOffline);
		}
		else
			request("GET", "/route?path=" + StringTools.urlEncode(path) + levelQuery(), null, onDone, onOffline);
	}

	function refreshRouteSummary() {
		jRouteSum.removeClass("g-route-bad");
		if( route == null ) {
			jRouteSum.text("");
			return;
		}
		if( route.success != true ) {
			jRouteSum.addClass("g-route-bad").text('No route: ${route.error != null ? route.error : "unknown error"}');
			return;
		}
		var steps : Array<Dynamic> = route.steps != null ? route.steps : [];
		var jumps = steps.filter( s->s.kind == "jump" ).length;
		var abilities = steps.filter( s->s.ability != null ).length;
		var html = esc('Route: ${steps.length} move${steps.length == 1 ? "" : "s"} ($jumps jump${jumps == 1 ? "" : "s"}, $abilities ability move${abilities == 1 ? "" : "s"})');
		var lost : Array<Dynamic> = route.unreachable_required != null ? route.unreachable_required : [];
		if( lost.length > 0 )
			html += ' <span class="g-route-lost">· ${lost.length} required entit${lost.length == 1 ? "y" : "ies"} unreachable</span>';
		jRouteSum.html(html);
	}

	function drawRoute() {
		var editor = activeEditor();
		var li = gridLayer();
		if( editor == null || li == null || route == null || !jRouteOn.prop("checked") || !samePath(routePath, currentProjectPath()) ) {
			routeOverlay.clear();
			return;
		}
		routeOverlay.draw(route, editor.curLevel, li.def.gridSize);
	}

	// ── Play mode (v3 Part 16) ────────────────────────────────────────────

	/** Saves unsaved changes (as edits do), then plays the current level. **/
	function play() {
		var path = editTargetPath();
		var editor = activeEditor();
		if( path == null || editor == null ) return;
		if( editor.curLevel == null ) {
			appendMsg("err", "Select a level to play first.");
			return;
		}
		saveFirst( ()-> {
			var editor = activeEditor();
			if( editor == null || editor.curLevel == null || !samePath(path, currentProjectPath()) ) return;
			setStatus("ready");
			ui.gldtk.GldtkPlay.open(editor.project, editor.curLevel, path);
		});
	}

	// ── Difficulty chart (v3 Part 15b) ────────────────────────────────────

	/** The difficulty of a generate / edit / undo response, for the file about to be reloaded. **/
	function takeDifficulty(d:Null<Dynamic>, path:String) {
		if( d == null || !samePath(path, currentProjectPath()) ) return;
		setDifficulty(d, path);
		difficultyFromResponse = true;
	}

	function setDifficulty(d:Dynamic, path:String) {
		cancelDifficultyFetch();
		difficultySeq++;
		difficulty = d;
		difficultyPath = path;
		drawDifficulty();
	}

	function clearDifficulty() {
		cancelDifficultyFetch();
		difficultySeq++;
		difficulty = null;
		difficultyPath = null;
		difficultyFromResponse = false;
		drawDifficulty();
	}

	function cancelDifficultyFetch() {
		if( difficultyTimer != null ) {
			difficultyTimer.stop();
			difficultyTimer = null;
		}
	}

	function scheduleDifficultyFetch() {
		cancelDifficultyFetch();
		if( currentProjectPath() == null ) return;
		difficultyTimer = haxe.Timer.delay( ()-> { difficultyTimer = null; fetchDifficulty(); }, DIFF_DEBOUNCE_MS );
	}

	/** GET /difficulty reads the saved file, so hand edits show once they are saved. **/
	function fetchDifficulty() {
		var path = currentProjectPath();
		if( path == null ) return;
		var seq = ++difficultySeq;
		request("GET", "/difficulty?path=" + StringTools.urlEncode(path) + levelQuery(), null, (status, res)-> {
			if( seq != difficultySeq || !samePath(path, currentProjectPath()) ) return;
			setDifficulty( status == 200 && res != null ? res : { success: false, error: errorText(status, res) }, path );
		}, ()-> {
			if( seq != difficultySeq ) return;
			difficulty = null;
			jDiff.empty();
		});
	}

	static function diffColor(label:String) : String
		return switch label { case "easy": "#5bc470"; case "hard": "#ff6b5b"; case _: "#f2b84b"; }

	function drawDifficulty() {
		jDiff.empty();
		if( difficulty == null || !samePath(difficultyPath, currentProjectPath()) ) return;
		var secs : Array<Dynamic> = difficulty.sections != null ? difficulty.sections : [];
		// /undo drops unset defaults from its response, so a missing `success` means true
		var ok = difficulty.success != false;
		if( !ok || secs.length == 0 ) {
			if( !ok )
				jDiff.html('<div class="g-diff-title g-route-bad">Difficulty: ${esc(difficulty.error != null ? difficulty.error : "unavailable")}</div>');
			return;
		}
		var overall = difficulty.overall != null ? ' · overall ${Std.string(Math.round(difficulty.overall*10)/10)}' : "";
		var html = '<div class="g-diff-title">Difficulty$overall</div><div class="g-diff-bars">';
		for( s in secs ) {
			var score : Float = s.score;
			var warns : Array<String> = s.warnings != null ? s.warnings : [];
			var tip = '${s.name}: ${s.label}, score ${Math.round(score*10)/10}/10';
			for( w in warns ) tip += '\n⚠ $w';
			var m : Dynamic = s.metrics;
			if( m != null )
				for( k in Reflect.fields(m) ) {
					var v : Dynamic = Reflect.field(m, k);
					if( Std.isOfType(v, Float) ) tip += '\n$k: ${Math.round((v:Float)*100)/100}';
				}
			html += '<div class="g-diff-bar" data-id="${esc(s.id)}" title="${esc(tip)}">' +
				'<div class="g-diff-warn">${warns.length > 0 ? "&#x26A0;" : ""}</div>' +
				'<div class="g-diff-col"><div class="g-diff-fill" style="height:${Std.int(Math.max(2, score*10))}%;background:${diffColor(s.label)}"></div></div>' +
				'<div class="g-diff-score">${Math.round(score*10)/10}</div>' +
				'<div class="g-diff-name">${esc(s.name)}</div>' +
				'<div class="g-diff-label" style="color:${diffColor(s.label)}">${esc(s.label)}</div></div>';
		}
		html += '</div>';
		var lw : Array<String> = difficulty.warnings != null ? difficulty.warnings : [];
		for( w in lw ) html += '<div class="g-diff-curve">&#x26A0; ${esc(w)}</div>';
		jDiff.html(html);
	}

	// ── Live progress + Cancel (v3 Part 14) ───────────────────────────────

	static function newJobId() : String {
		var crypto : Dynamic = untyped js.Browser.window.crypto;
		if( crypto != null && crypto.randomUUID != null )
			return crypto.randomUUID();
		return [ for( _ in 0...4 ) StringTools.hex(Std.random(0x10000), 4) + StringTools.hex(Std.random(0x10000), 4) ].join("-");
	}

	/** A new job id for the next request; polls `/progress` until `endJob()`. **/
	function startJob() : String {
		endJob();
		var j : GldtkJob = { id: newJobId(), startedAt: haxe.Timer.stamp(), timer: new haxe.Timer(PROGRESS_POLL_MS), polling: false, cancelling: false };
		job = j;
		j.timer.run = ()-> pollProgress(j);
		jProgMsg.text("Sending the request…");
		jProgLog.empty();
		jProgress.addClass("on");
		tickElapsed();
		return j.id;
	}

	/** Stops polling and hides the progress; returns whether Cancel had been pressed. **/
	function endJob() : Bool {
		if( job == null ) return false;
		var cancelling = job.cancelling;
		stopPolling();
		job = null;
		jProgress.removeClass("on");
		return cancelling;
	}

	function stopPolling() {
		if( job != null && job.timer != null ) {
			job.timer.stop();
			job.timer = null;
		}
	}

	function tickElapsed() {
		if( job == null ) return;
		var s = Std.int( haxe.Timer.stamp() - job.startedAt );
		jProgTime.text( '${Std.int(s / 60)}:${StringTools.lpad(Std.string(s % 60), "0", 2)}' );
	}

	function pollProgress(j:GldtkJob) {
		if( job != j ) return;
		tickElapsed();
		if( j.polling ) return; // the previous poll has not answered yet
		j.polling = true;
		request("GET", "/progress?job=" + StringTools.urlEncode(j.id), null, (status, res)-> {
			j.polling = false;
			if( job != j || status != 200 || res == null ) return;
			var events : Array<Dynamic> = res.events != null ? res.events : [];
			if( events.length == 0 ) return;
			if( !j.cancelling )
				jProgMsg.text( Std.string(events[events.length-1].message) );
			jProgLog.html( events.map( e->'<li><span class="g-prog-t">${fmtSeconds(e.t)}</span>${esc(e.message)}</li>' ).join("") );
		}, ()-> j.polling = false );
	}

	static function fmtSeconds(t:Dynamic) : String {
		var s = Std.int( t != null ? (t:Float) : 0 );
		return '${Std.int(s / 60)}:${StringTools.lpad(Std.string(s % 60), "0", 2)}';
	}

	/** Cancel button / Esc: the server stops at its next checkpoint and writes nothing. **/
	function cancelJob() {
		var j = job;
		if( j == null || j.cancelling ) return;
		j.cancelling = true;
		jProgMsg.text("Cancelling… (waits for the current LLM call to return)");
		jBtn.prop("disabled", true);
		jEditBtn.prop("disabled", true);
		setStatus("cancelling…");
		request("POST", "/cancel", { job_id: j.id }, (_, _)->{}, ()->{} );
	}

	function onCancelled() {
		appendMsg("ai", '<span class="g-meta g-edit-meta">&#x25A0; Cancelled</span>Cancelled. Nothing was changed.');
		setStatus("cancelled");
	}

	/** Cancel was pressed, but the result was already being written. **/
	function noteTooLate() {
		appendMsg("ai", "It finished before the cancel arrived, so the result was kept.");
	}

	// ── Multi-level worlds (v3 Part 17b) ──────────────────────────────────

	function curLevelIid() : Null<String> {
		var editor = activeEditor();
		return editor != null && editor.curLevel != null ? editor.curLevel.iid : null;
	}

	function levelQuery() : String {
		var lv = curLevelIid();
		return lv == null ? "" : "&level=" + StringTools.urlEncode(lv);
	}

	function levelLabel(iid:String) : String {
		var editor = activeEditor();
		if( editor != null )
			for( l in editor.curWorld.levels )
				if( l.iid == iid ) return l.identifier;
		return iid;
	}

	/** Keeps the level titles and scores of a generate / edit / undo response; edits send null scores for the levels they skipped. **/
	function takeLevels(res:Dynamic, path:String) {
		var lvs : Array<Dynamic> = res.levels;
		if( lvs == null || lvs.length == 0 ) return;
		if( res.world != null ) fullReload = true;
		if( levelInfoPath == null || !samePath(levelInfoPath, path) || res.world != null ) {
			levelInfo = new Map();
			levelInfoPath = path;
		}
		for( l in lvs ) {
			if( l.iid == null ) continue;
			var info : Dynamic = levelInfo.exists(l.iid) ? levelInfo.get(l.iid) : {};
			if( l.title != null ) info.title = l.title;
			if( l.score != null ) info.score = l.score;
			if( l.verified != null ) info.verified = l.verified;
			levelInfo.set(l.iid, info);
			if( l.current == true && lvs.length > 1 ) reselectIid = l.iid;
		}
		refreshLevels();
	}

	/** After a reload LDtk shows the first level: go back to the one the response was about. **/
	function reselectLevel() {
		var iid = reselectIid;
		reselectIid = null;
		var editor = activeEditor();
		if( iid == null || editor == null ) return;
		for( l in editor.curWorld.levels )
			if( l.iid == iid ) {
				if( editor.curLevel != l ) editor.selectLevel(l, true);
				return;
			}
	}

	function refreshLevels() {
		var editor = activeEditor();
		var lvs = editor != null && editor.curWorld != null ? editor.curWorld.levels : [];
		if( lvs.length < 2 ) {
			jLevelBox.removeClass("open");
			jLevelList.empty();
			return;
		}
		jLevelBox.addClass("open");
		var cur = curLevelIid();
		var known = samePath(levelInfoPath, currentProjectPath());
		var rows = new StringBuf();
		for( l in lvs ) {
			var info : Dynamic = known && levelInfo.exists(l.iid) ? levelInfo.get(l.iid) : null;
			var title = info != null && info.title != null ? ' <span class="g-lv-title">${esc(info.title)}</span>' : "";
			var score = info != null && info.score != null ? '<span class="g-lv-score">${Math.round(info.score * 100)}%</span>' : "";
			rows.add('<div class="g-lv${l.iid == cur ? " cur" : ""}" data-iid="${esc(l.iid)}"><span class="g-lv-id">${esc(l.identifier)}</span>$title$score</div>');
		}
		jLevelList.html(rows.toString());
		jLevelEditing.text('Editing: ${cur != null ? levelLabel(cur) : "-"}');
	}

	function levelPrompt(iid:String) : String {
		var editor = activeEditor();
		if( editor != null )
			for( l in editor.curWorld.levels )
				if( l.iid == iid )
					for( fi in l.fieldInstances )
						if( fi.def.identifier == "gldtk_prompt" && !fi.valueIsNull(0) ) return fi.getString(0);
		return "";
	}

	function regenerateLevel() {
		var iid = curLevelIid();
		if( iid == null || editTargetPath() == null ) return;
		saveFirst( ()-> generate(iid, levelPrompt(iid)) );
	}

	function worldHtml(w:Null<Dynamic>) : String {
		if( w == null ) return "";
		var lvs : Array<Dynamic> = w.levels != null ? w.levels : [];
		var score : Null<Float> = w.requirements_score;
		return '<span class="g-meta">World ${w.title != null ? esc(w.title) : ""} · ${lvs.length} levels' +
			( score != null ? ' · ${Math.round(score * 100)}%' : "" ) + '</span>';
	}

	// ── Generate ──────────────────────────────────────────────────────────

	/** `regenLevel`: iid of the one level to regenerate; its own prompt is used when `description` is empty. **/
	function generate(?regenLevel:String, ?levelPrompt:String) {
		var description = regenLevel != null ? levelPrompt : StringTools.trim( jPrompt.val() );
		if( regenLevel == null && description.length == 0 ) return;

		// Require an open project
		var outPath = currentProjectPath();
		refreshFileRow();
		if( outPath == null ) {
			appendMsg("err", "Open a .ldtk project in LDtk first, then generate.");
			return;
		}

		appendMsg("user", regenLevel != null
			? '<span class="g-meta">&#x21BB; Regenerate ${esc(levelLabel(regenLevel))}</span>' + esc(description)
			: esc(description));

		var payload : Dynamic = {
			description: description,
			output_path: outPath,
			seed:        Std.int( Math.random() * 100000 ),
			provider:    jProvider.val(),
			job_id:      startJob(),
		};
		var model = StringTools.trim( jModel.val() );
		if( model.length > 0 )
			Reflect.setField(payload, "model", model);
		if( regenLevel != null )
			payload.level = regenLevel;
		else if( jLevels.val() != "" )
			payload.levels = Std.parseInt( jLevels.val() );

		setBusy(true);
		setStatus("generating…");

		request("POST", "/generate", payload, (status, res)-> {
			var cancelling = endJob();
			setBusy(false);
			if( status == 200 && res != null && res.cancelled == true )
				onCancelled();
			else if( status != 200 ) {
				appendMsg("err", 'Server returned HTTP ${status}.');
				setStatus("error");
			}
			else if( res == null ) {
				appendMsg("err", "Parse error — invalid JSON from server.");
				setStatus("error");
			}
			else if( res.success == false ) {
				appendMsg("err", res.error != null ? esc(res.error) : "Unknown error");
				setStatus("error");
			}
			else {
				if( cancelling ) noteTooLate();
				onSuccess(res, outPath);
			}
		}, ()-> {
			endJob();
			setBusy(false);
			appendMsg("err", "Cannot reach GLDtk server — is <code>python server.py</code> running?");
			setStatus("offline");
		});
	}

	/** Shows a generate or edit result, then reloads the level in place. `header`: edit summary. **/
	function onSuccess(res:Dynamic, writtenPath:String, header="") {
		var s        : Dynamic = res.stats   != null ? res.stats   : {};
		var themeStr : String  = s.theme     != null ? s.theme     : "";
		var nodes    : Int     = s.nodes     != null ? s.nodes     : 0;
		var edges    : Int     = s.edges     != null ? s.edges     : 0;
		var entMap   : Dynamic = s.entities;
		var etParts  = [];
		if( entMap != null )
			for( k in Reflect.fields(entMap) )
				etParts.push( Reflect.field(entMap, k) + "×" + k );

		if( res.output_path != null ) writtenPath = res.output_path;
		takeLevels(res, writtenPath);
		takeRoute(res.route, writtenPath);
		takeDifficulty(res.difficulty, writtenPath);
		refreshMemory();
		var verified = res.verified == true ? "beatable" : "not verified";

		var warnings : Array<String> = res.warnings != null ? res.warnings : [];
		var warnHtml = warnings.length == 0 ? "" :
			'<details class="g-fold"><summary>${warnings.length} warning${warnings.length > 1 ? "s" : ""}</summary>' +
			'<ul class="g-warn-list">' + warnings.map( w->'<li>${esc(w)}</li>' ).join("") + '</ul></details>';

		var ascii = res.preview_ascii != null
			? '<details class="g-fold"><summary>Preview</summary><pre class="g-ascii">${esc(res.preview_ascii)}</pre></details>'
			: "";

		appendMsg("ai",
			header +
			'<span class="g-meta">${esc(themeStr)} · $nodes nodes · $edges edges · $verified · ${etParts.join(" ")}</span>' +
			worldHtml(res.world) +
			fidelityHtml(res.fidelity) +
			warnHtml +
			ascii +
			'<span class="g-ok">&#x2713; Saved ${esc(writtenPath.split("/").pop())}</span>'
		);
		setStatus("reloading…");
		haxe.Timer.delay( ()-> reloadGeneratedProject(writtenPath), 400 );
	}

	static function statusIcon(status:String) : String {
		return switch status {
			case "satisfied":    "&#x2705;";
			case "approximated": "&#x26A0;";
			case "impossible", "missing": "&#x274C;";
			case _:              "&middot;";
		}
	}

	function fidelityHtml(f:Dynamic) : String {
		if( f == null ) return "";

		var score : Null<Float> = f.score;
		var scoreStr = score == null ? "n/a" : Math.round(score * 100) + "%";
		var counts = [];
		for( st in STATUSES ) {
			var n : Null<Int> = f.counts != null ? Reflect.field(f.counts, st) : null;
			if( n != null && n > 0 )
				counts.push('${statusIcon(st)} $n $st');
		}

		var rows = new StringBuf();
		var items : Array<Dynamic> = f.items != null ? f.items : [];
		for( it in items ) {
			var status : String = it.status;
			var auto = it.auto_filled == true ? '<span class="g-tag">auto</span>' : "";
			rows.add(
				'<details class="g-req g-req-$status">' +
				'<summary title="${esc(it.reason)}"><span class="g-req-icon">${statusIcon(status)}</span>' +
				'<span class="g-req-text">${esc(it.text)}</span>$auto</summary>' +
				'<div class="g-req-reason">${esc(status)}: ${esc(it.reason)}</div></details>'
			);
		}

		return
			'<div class="g-fid">' +
			'<div class="g-fid-head"><span class="g-fid-score">Fidelity $scoreStr</span>' +
			'<span class="g-fid-counts">${counts.join("&nbsp;&nbsp;")}</span></div>' +
			rows.toString() +
			'</div>';
	}

	static function samePath(a:Null<String>, b:Null<String>) : Bool {
		if( a == null || b == null ) return false;
		return js.node.Path.resolve(a) == js.node.Path.resolve(b);
	}

	function reloadGeneratedProject(path:String) {
		// The user may have switched or closed projects while the server was working:
		// the file is saved either way, but only the project it belongs to is reloaded.
		if( !samePath(currentProjectPath(), path) ) {
			var parts = path.split("/");
			var shortPath = parts.slice(-2).join("/");
			appendMsg("ai", 'Saved ${esc(shortPath)}. It was not opened because another project is open now.');
			setStatus("ready");
			return;
		}
		var editor = activeEditor();

		// Swap the project inside the open Editor, as LastChance does. Re-opening it
		// with App.loadProject() would replace the Editor page with a new one, and the
		// old page's deferred onDispose() would then hide the new page's canvas.
		new ui.ProjectLoader(
			path,
			(p)-> {
				if( editor.destroyed ) {
					App.ME.loadProject(path, null, (q)-> setStatus(q != null ? "ready" : "error") );
					return;
				}
				editor.selectProject(p);
				if( fullReload ) {
					// new levels: the world render still holds the old ones and would crash on the next viewport change
					fullReload = false;
					editor.selectWorld(p.worlds[0], false);
				}
				editor.resetTools();
				editor.camera.fit(true);
				editor.updateTitle();
				App.ME.registerRecentProject(p.filePath.full);
				reselectLevel();
				setStatus("ready");
			},
			(err)-> {
				appendMsg("err", 'Reload failed (${esc(err)}). Open the file again from LDtk.');
				setStatus("error");
			}
		);
	}
}
