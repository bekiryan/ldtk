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

	var jRoot      : J;
	var jToggle    : J;
	var jHistory   : J;
	var jPrompt    : J;
	var jBtn       : J;
	var jStatus    : J;
	var jFile      : J;
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

	function restoreState() {
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

		appendMsg("user", description);

		setBusy(true);
		setStatus("generating…");

		var payload : Dynamic = {
			description: description,
			output_path: outPath,
			seed:        Std.int( Math.random() * 100000 ),
		};

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
		haxe.Timer.delay( ()-> reloadGeneratedProject(writtenPath), 400 );
	}

	function reloadGeneratedProject(path:String) {
		var done = false;
		var fallbackUsed = false;

		var fallback = function(reason:String) {
			if( fallbackUsed ) return;
			fallbackUsed = true;
			appendMsg("err", 'Reload failed ($reason). Refreshing window…');
			setStatus("refreshing…");
			js.Browser.window.location.reload();
		};

		// If project reload gets stuck in loading, force a hard refresh.
		haxe.Timer.delay( ()-> {
			if( !done ) fallback("timeout");
		}, 3000 );

		try {
			App.ME.loadProject(path, null, (p)-> {
				done = true;
				if( p == null )
					fallback("project load error");
				else {
					// Success: fit camera on the first level
					try {
						var editor = page.Editor.ME;
						if( editor != null && editor.curLevel != null ) {
							editor.selectLevel(editor.curLevel, true);  // fitView=true
							editor.camera.fit(true);
							editor.updateTitle();
							setStatus("ready");
						}
					}
					catch(err:Dynamic) {
						fallback("camera fit error: " + Std.string(err));
					}
				}
			});
		}
		catch(err:Dynamic) {
			done = true;
			fallback(Std.string(err));
		}
	}
}
