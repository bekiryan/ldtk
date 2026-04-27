package ui;

/**
  GLDtk sidebar — persistent right-hand panel, styled to match LDtk's
  native design. Uses XMLHttpRequest so it runs through Electron's renderer
  XHR stack rather than Node's http module.

  Output path is always the currently open project file — no manual input.
**/
class GldtkSidebar {

	static inline var SERVER   = "http://127.0.0.1:8765";
	static inline var HIST_KEY = "gldtk_history";
	static inline var DIFF_KEY = "gldtk_difficulty";

	var jRoot      : J;
	var jToggle    : J;
	var jHistory   : J;
	var jPrompt    : J;
	var jBtn       : J;
	var jStatus    : J;
	var jFile      : J;
	var difficulty : String = "medium";
	var collapsed  : Bool   = false;
	var busy       : Bool   = false;

	public function new() {
		injectCss();
		buildDom();
		restoreState();
		restoreHistory();
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
		new J("body").append(jToggle);

		jRoot = new J('<div id="gldtk-root"></div>');
		jRoot.html('
			<div class="g-titlebar">
				<span class="g-title">GLDtk</span>
				<span class="g-status" id="g-status">ready</span>
			</div>

			<div class="g-history" id="g-history"></div>

			<div class="g-form">

				<div class="g-file-row" id="g-file-row">
					<span class="g-file-label">No project open</span>
				</div>

				<div class="g-section">THEME</div>
				<div class="g-field">
					<select id="g-theme">
						<option value="">Auto-detect</option>
						<option value="dungeon">Dungeon</option>
						<option value="forest">Forest</option>
						<option value="sky">Sky</option>
					</select>
				</div>

				<div class="g-section">DIFFICULTY</div>
				<div class="g-field g-diff-row">
					<button id="dEasy"   class="g-diff-btn">Easy</button>
					<button id="dMedium" class="g-diff-btn">Med</button>
					<button id="dHard"   class="g-diff-btn">Hard</button>
				</div>

				<div class="g-section">ENEMIES &nbsp;<span class="g-hint">comma-separated</span></div>
				<div class="g-field">
					<input type="text" id="g-enemies" placeholder="Goblin, Slime, …"/>
				</div>

				<div class="g-section">PLATFORMS</div>
				<div class="g-field">
					<input type="number" id="g-platforms" min="2" max="30" placeholder="auto"/>
				</div>

				<div class="g-section">SIZE &nbsp;<span class="g-hint">width × height tiles</span></div>
				<div class="g-field g-size-row">
					<input type="number" id="g-width"  min="20" max="300" placeholder="60"/>
					<span class="g-size-x">×</span>
					<input type="number" id="g-height" min="10" max="100" placeholder="20"/>
				</div>

				<div class="g-section">PROMPT</div>
				<div class="g-field">
					<textarea id="g-prompt" rows="4"
					          placeholder="Describe the level… (Ctrl+Enter to generate)"></textarea>
				</div>

				<div class="g-field">
					<button id="g-btn" class="g-gen-btn">&#x25B6;&nbsp; Generate</button>
				</div>

			</div>
		');
		new J("body").append(jRoot);

		jHistory = jRoot.find("#g-history");
		jPrompt  = jRoot.find("#g-prompt");
		jBtn     = jRoot.find("#g-btn");
		jStatus  = jRoot.find("#g-status");
		jFile    = jRoot.find("#g-file-row");

		jBtn.click( _-> if( !busy ) generate() );
		jRoot.find("#dEasy").click(   _-> setDiff("easy")   );
		jRoot.find("#dMedium").click( _-> setDiff("medium") );
		jRoot.find("#dHard").click(   _-> setDiff("hard")   );

		jPrompt.on("keydown", function(ev:js.jquery.Event) {
			var ke : js.html.KeyboardEvent = cast Reflect.field(ev, "originalEvent");
			if( ke != null && ke.key == "Enter" && (ke.ctrlKey || ke.metaKey) ) generate();
		});
	}

	// ── Current project path ──────────────────────────────────────────────

	function currentProjectPath() : Null<String> {
		if( Editor.ME == null || Editor.ME.project == null ) return null;
		var fp = Editor.ME.project.filePath;
		if( fp == null ) return null;
		return fp.full;
	}

	function refreshFileRow() {
		var path = currentProjectPath();
		if( path != null ) {
			var name = path.split("/").pop();
			jFile.html('<span class="g-file-icon">&#x1F4C4;</span><span class="g-file-name">$name</span>');
			jFile.removeClass("g-file-none");
		} else {
			jFile.html('<span class="g-file-label">No project open — open a .ldtk file first</span>');
			jFile.addClass("g-file-none");
		}
	}

	// ── Persist / restore ─────────────────────────────────────────────────

	function saveStr(k:String, v:String) js.Browser.window.localStorage.setItem(k, v);

	function loadStr(k:String, ?def:String) : String {
		var v = js.Browser.window.localStorage.getItem(k);
		return v != null ? v : (def != null ? def : "");
	}

	function restoreState() {
		setDiff( loadStr(DIFF_KEY, "medium") );
		refreshFileRow();
	}

	function restoreHistory() {
		var saved = js.Browser.window.localStorage.getItem(HIST_KEY);
		if( saved != null ) {
			jHistory.html(saved);
			jHistory.scrollTop( jHistory.prop("scrollHeight") );
		}
	}

	function persistHistory() saveStr(HIST_KEY, jHistory.html());

	// ── UI helpers ────────────────────────────────────────────────────────

	function toggleCollapse() {
		collapsed = !collapsed;
		if( !collapsed ) refreshFileRow();
		jRoot.toggleClass("collapsed", collapsed);
		jToggle.toggleClass("open", !collapsed);
	}

	function setDiff(d:String) {
		difficulty = d;
		saveStr(DIFF_KEY, d);
		for( n in ["Easy","Medium","Hard"] )
			jRoot.find("#d"+n).toggleClass("active", n.toLowerCase() == d);
	}

	function setStatus(s:String) jStatus.text(s);

	function appendMsg(cls:String, html:String) {
		var el = new J('<div class="g-msg g-msg-${cls}"></div>');
		el.html(html);
		jHistory.append(el);
		jHistory.scrollTop( jHistory.prop("scrollHeight") );
		persistHistory();
	}

	function setBusy(b:Bool) {
		busy = b;
		jBtn.prop("disabled", b);
		jBtn.html( b ? "Generating…" : "&#x25B6;&nbsp; Generate" );
	}

	// ── Generate ──────────────────────────────────────────────────────────

	function generate() {
		var description = StringTools.trim( jPrompt.val() );
		if( description.length == 0 ) return;

		// Require an open project
		var outPath = currentProjectPath();
		refreshFileRow();
		if( outPath == null ) {
			appendMsg("err", "Open a .ldtk project in LDtk first, then generate.");
			return;
		}

		var theme      = jRoot.find("#g-theme").val();
		var enemiesRaw = jRoot.find("#g-enemies").val();
		var platRaw    = jRoot.find("#g-platforms").val();

		var enemies : Array<String> = [];
		if( enemiesRaw != null && StringTools.trim(enemiesRaw).length > 0 )
			enemies = [for( s in enemiesRaw.split(",") ) StringTools.trim(s)].filter( s -> s.length > 0 );

		var platforms : Null<Int> = null;
		if( platRaw != null && platRaw != "" ) {
			var p = Std.parseInt(platRaw);
			if( p != null && p > 0 ) platforms = p;
		}

		var widthTiles  : Null<Int> = null;
		var heightTiles : Null<Int> = null;
		var wRaw = jRoot.find("#g-width").val();
		var hRaw = jRoot.find("#g-height").val();
		if( wRaw != null && wRaw != "" ) { var v = Std.parseInt(wRaw); if( v != null && v >= 20 ) widthTiles  = v; }
		if( hRaw != null && hRaw != "" ) { var v = Std.parseInt(hRaw); if( v != null && v >= 10 ) heightTiles = v; }

		var metaParts = [];
		if( theme != null && theme != "" ) metaParts.push("theme:" + theme);
		if( enemies.length > 0 ) metaParts.push("enemies:" + enemies.join("+"));
		if( platforms != null )  metaParts.push("platforms:" + platforms);
		metaParts.push("difficulty:" + difficulty);
		appendMsg("user", '<span class="g-meta">${metaParts.join(" · ")}</span>${description}');

		setBusy(true);
		setStatus("generating…");

		var payload : Dynamic = {
			description: description,
			difficulty:  difficulty,
			output_path: outPath,
			seed:        Std.int( Math.random() * 100000 ),
		};
		if( theme != null && theme != "" ) Reflect.setField(payload, "theme", theme);
		if( enemies.length > 0 )           Reflect.setField(payload, "enemy_types", enemies);
		if( platforms != null )            Reflect.setField(payload, "platform_count", platforms);
		if( widthTiles  != null )          Reflect.setField(payload, "width_tiles",  widthTiles);
		if( heightTiles != null )          Reflect.setField(payload, "height_tiles", heightTiles);

		var xhr = new js.html.XMLHttpRequest();
		xhr.open("POST", SERVER + "/generate");
		xhr.setRequestHeader("Content-Type", "application/json");

		xhr.onload = function(_) {
			setBusy(false);
			if( xhr.status == 200 ) {
				var res : Dynamic;
				try { res = haxe.Json.parse(xhr.responseText); }
				catch(_) {
					appendMsg("err", "Parse error — invalid JSON from server.");
					setStatus("error");
					return;
				}
				if( res.success == false ) {
					appendMsg("err", res.error != null ? res.error : "Unknown error");
					setStatus("error");
				} else {
					onSuccess(res, outPath);
				}
			} else {
				appendMsg("err", 'Server returned HTTP ${xhr.status}.');
				setStatus("error");
			}
		};

		xhr.onerror = function(_) {
			setBusy(false);
			appendMsg("err", "Cannot reach GLDtk server — is <code>python server.py</code> running?");
			setStatus("offline");
		};

		xhr.send(haxe.Json.stringify(payload));
	}

	function onSuccess(res:Dynamic, writtenPath:String) {
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

		var ascii = res.preview_ascii != null
			? '<pre class="g-ascii">${res.preview_ascii}</pre>'
			: "";

		appendMsg("ai",
			'<span class="g-meta">$themeStr · $nodes nodes · $edges edges · ${etParts.join(" ")}</span>' +
			ascii +
			'<span class="g-ok">&#x2713; Saved — reloading…</span>'
		);
		setStatus("reloading…");
		haxe.Timer.delay( ()-> App.ME.loadProject(writtenPath), 400 );
	}
}
