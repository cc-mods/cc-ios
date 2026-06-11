// cc-ios Title Buttons — adds native "Restart Game" and "Close Game" entries to the
// CrossCode title-screen menu, positioned below the Options button.
//
// CrossCode builds the title menu in sc.TitleScreenButtonGui.init via _createButton,
// stacking sc.ButtonGui entries bottom-anchored (x=12, y=offset; larger y = higher).
// On iOS the native "close" button is skipped (it's DESKTOP-gated and uses nw.gui), so
// we add our own: shift the existing left-column buttons up by two slots and place
// Restart + Close in the freed bottom slots, grouped under Options.
//
// Actions:
//   Restart -> reload the web view (full game re-boot)
//   Close   -> post to the native ControlBridge (exit the app); falls back to window.close
(function () {
	function postControl(action) {
		try {
			window.webkit.messageHandlers.cccontrol.postMessage(action);
			return true;
		} catch (e) { return false; }
	}

	if (typeof sc === "undefined" || !sc.TitleScreenButtonGui) {
		console.warn("[cc-ios] TitleScreenButtonGui unavailable; skipping title buttons");
		return;
	}

	sc.TitleScreenButtonGui.inject({
		init: function () {
			this.parent();
			// Never let button setup throw into the game's init (→ CRITICAL BUG screen).
			try {
				this._cciosAddSystemButtons();
			} catch (e) {
				console.error("[cc-ios] title buttons failed (non-fatal):", e);
			}
		},

		_cciosAddSystemButtons: function () {
			if (!this.buttons || !this.buttons.length || !this.buttonGroup) return;

			// Slot height from a real button; shift the existing column up to make room.
			var slot = this.buttons[0].hook.size.y + 4;
			for (var i = 0; i < this.buttons.length; i++) {
				this.buttons[i].hook.pos.y += slot * 2;
			}

			// Use focus indices well clear of the game's (0–5) to avoid nav collisions.
			this._cciosButton("Restart Game", 12 + slot, 20, function () {
				if (!postControl("restart")) { try { window.location.reload(); } catch (e) {} }
			});
			this._cciosButton("Close Game", 12, 21, function () {
				postControl("quit");
			});
		},

		// Mirrors _createButton but with explicit label text (no lang dependency).
		_cciosButton: function (label, yOffset, focusIndex, onPress) {
			var btn = new sc.ButtonGui(label, sc.BUTTON_DEFAULT_WIDTH);
			btn.setPos(12, yOffset);
			btn.setAlign(ig.GUI_ALIGN.X_LEFT, ig.GUI_ALIGN.Y_BOTTOM);
			btn.hook.transitions = {
				DEFAULT: { state: {}, time: 0.2, timeFunction: KEY_SPLINES.EASE },
				HIDDEN: { state: { offsetX: -(sc.BUTTON_DEFAULT_WIDTH + 12) }, time: 0.2, timeFunction: KEY_SPLINES.LINEAR }
			};
			btn.onButtonPress = function () {
				try { onPress(); } catch (e) { console.error("[cc-ios] button action failed:", e); }
			};
			btn.doStateTransition("DEFAULT", true);
			this.buttonGroup.addFocusGui(btn, 0, focusIndex);
			this.addChildGui(btn);
			this.buttons.push(btn);
		}
	});
})();
