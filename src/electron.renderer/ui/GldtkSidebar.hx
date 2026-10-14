package ui;

typedef ProfileField = { path:String, label:String, ?bool:Bool }
typedef ProfileGroup = { title:String, ?toggle:String, fields:Array<ProfileField> }

/**
  GLDtk sidebar — persistent right-hand panel, styled to match LDtk's
  native design. Uses XMLHttpRequest so it runs through Electron's renderer
  XHR stack rather than Node's http module.

  Output path is always the currently open project file — no manual input.
**/
class GldtkSidebar {

	static inline var SERVER       = "http://127.0.0.1:8765";
	static inline var HIST_KEY     = "gldtk_history";
	static inline var PROVIDER_KEY = "gldtk_provider";
	static inline var MODEL_KEY    = "gldtk_model";
	static inline var PROFILE_KEY  = "gldtk_profile_open";

	static var PROVIDERS = ["gemini", "anthropic", "ollama", "openai", "deepseek"];
	static var STATUSES  = ["satisfied", "approximated", "impossible", "missing", "unchecked"];

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
	var collapsed  : Bool   = false;
	var busy       : Bool   = false;

	var defaultModels : Map<String,String> = new Map();
	var profile       : Null<Dynamic>;   // last profile loaded from or saved to the server
	var profilePath   : Null<String>;    // project the profile belongs to

	public function new() {
		injectCss();
		buildDom();
		restoreState();
		restoreHistory();
		loadProviders();
		onProjectChanged();
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

		var providerOpts = PROVIDERS.map( p->'<option value="$p">$p</option>' ).join("");

		// Part 8 adds the regional editing controls (section dropdown, rectangle
		// selection, undo) to #g-edit.
		jRoot = new J('<div id="gldtk-root"></div>');
		jRoot.html('
			<div class="g-titlebar">
				<span class="g-title">GLDtk</span>
				<span class="g-status" id="g-status">ready</span>
				<button class="g-clear" id="g-clear" title="Clear the chat history">clear</button>
			</div>

			<div class="g-history" id="g-history"></div>

			<div class="g-form">

				<div class="g-file-row" id="g-file-row">
					<span class="g-file-label">No project open</span>
				</div>

				<div class="g-fold-head" id="g-prof-head">
					<span class="g-caret"></span>GAME PROFILE
					<span class="g-hint" id="g-prof-note"></span>
				</div>
				<div class="g-prof" id="g-prof">
					${profileFormHtml()}
					<div class="g-prof-err" id="g-prof-err"></div>
					<button class="g-prof-save" id="g-prof-save">Save profile</button>
				</div>

				<div class="g-edit" id="g-edit"></div>

				<div class="g-section">PROVIDER</div>
				<div class="g-field g-provider-row">
					<select id="g-provider">$providerOpts</select>
					<input id="g-model" type="text" placeholder="default model"/>
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
		jProfErr  = jRoot.find("#g-prof-err");

		jBtn.click( _-> if( !busy ) generate() );
		jRoot.find("#g-clear").click( _-> clearHistory() );

		jPrompt.on("keydown", function(ev:js.jquery.Event) {
			var ke : js.html.KeyboardEvent = cast Reflect.field(ev, "originalEvent");
			if( ke != null && ke.key == "Enter" && (ke.ctrlKey || ke.metaKey) ) generate();
		});

		jProvider.change( _-> {
			saveStr(PROVIDER_KEY, jProvider.val());
			updateModelPlaceholder();
		});
		jModel.on("input", _-> saveStr(MODEL_KEY, StringTools.trim(jModel.val())) );

		jProfHead.click( _-> setProfileOpen( !jProfHead.hasClass("open") ) );
		jRoot.find("#g-prof-save").click( _-> saveProfile() );
		jProf.find("input[type=checkbox]").change( _-> updateAbilityToggles() );
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
		onProjectChanged();
	}

	function onEditorEvent(e:GlobalEvent) {
		switch e {
			case ProjectSelected, ProjectSaved: onProjectChanged();
			case _:
		}
	}

	function onProjectChanged() {
		refreshFileRow();
		if( currentProjectPath() != profilePath || profile == null )
			loadProfile();
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

	/** JSON request; `res` is null when the body is not JSON. **/
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
		xhr.send( body != null ? haxe.Json.stringify(body) : null );
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

	function setBusy(b:Bool) {
		busy = b;
		jBtn.prop("disabled", b);
		jBtn.html( b ? "Generating…" : "&#x25B6;&nbsp; Generate" );
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

		appendMsg("user", esc(description));

		setBusy(true);
		setStatus("generating…");

		var payload : Dynamic = {
			description: description,
			output_path: outPath,
			seed:        Std.int( Math.random() * 100000 ),
			provider:    jProvider.val(),
		};
		var model = StringTools.trim( jModel.val() );
		if( model.length > 0 )
			Reflect.setField(payload, "model", model);

		request("POST", "/generate", payload, (status, res)-> {
			setBusy(false);
			if( status != 200 ) {
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
			else
				onSuccess(res, outPath);
		}, ()-> {
			setBusy(false);
			appendMsg("err", "Cannot reach GLDtk server — is <code>python server.py</code> running?");
			setStatus("offline");
		});
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
		var verified = res.verified == true ? "beatable" : "not verified";

		var warnings : Array<String> = res.warnings != null ? res.warnings : [];
		var warnHtml = warnings.length == 0 ? "" :
			'<details class="g-fold"><summary>${warnings.length} warning${warnings.length > 1 ? "s" : ""}</summary>' +
			'<ul class="g-warn-list">' + warnings.map( w->'<li>${esc(w)}</li>' ).join("") + '</ul></details>';

		var ascii = res.preview_ascii != null
			? '<details class="g-fold"><summary>Preview</summary><pre class="g-ascii">${esc(res.preview_ascii)}</pre></details>'
			: "";

		appendMsg("ai",
			'<span class="g-meta">${esc(themeStr)} · $nodes nodes · $edges edges · $verified · ${etParts.join(" ")}</span>' +
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

	function reloadGeneratedProject(path:String) {
		var editor = activeEditor();
		if( editor == null ) {
			// No Editor page (eg. Home): open the project like LDtk does
			App.ME.loadProject(path, null, (p)-> setStatus(p != null ? "ready" : "error") );
			return;
		}

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
				editor.resetTools();
				editor.camera.fit(true);
				editor.updateTitle();
				App.ME.registerRecentProject(p.filePath.full);
				setStatus("ready");
			},
			(err)-> {
				appendMsg("err", 'Reload failed (${esc(err)}). Open the file again from LDtk.');
				setStatus("error");
			}
		);
	}
}
