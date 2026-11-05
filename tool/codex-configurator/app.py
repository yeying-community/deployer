"""Windows desktop UI; all mutations are delegated to config_core."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import tkinter as tk
from tkinter import filedialog
import webbrowser

import customtkinter as ctk

import config_core as core

BG = "#101217"
CARD = "#1A1D26"
TEXT = "#F3F4F8"
MUTED = "#A3A9BA"
ACCENT = "#8B92FF"
BORDER = "#303543"
FONT = "Microsoft YaHei UI"


class Configurator(ctk.CTk):
    def __init__(self, path: Path | None = None):
        super().__init__()
        self.title("夜莺 Codex 配置器")
        self.geometry("600x690")
        self.minsize(560, 600)
        self.configure(fg_color=BG)
        self.path = path
        self.auto_path = path is None
        self.path_settings_open = False
        self.path_error = ""
        if path is None:
            try:
                self.path = core.config_path()
            except core.ConfigError as exc:
                self.path_error = str(exc)
        self.key_var = tk.StringVar()
        self.model_var = tk.StringVar(value=core.MODEL)
        self.target = "Codex App"
        self.buttons = {}
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)
        body = ctk.CTkScrollableFrame(self, fg_color=BG, corner_radius=0)
        body.grid(row=0, column=0, sticky="nsew", padx=(12, 2), pady=(8, 0))
        body.grid_columnconfigure(0, weight=1)
        self.body = body
        self._build()
        self.refresh_path()
        self.load_model()
        self.after(150, self.key_entry.focus_set)

    def label(self, parent, text, size=14, color=TEXT, weight="normal", **kw):
        return ctk.CTkLabel(parent, text=text, font=(FONT, size, weight), text_color=color, **kw)

    def _build(self):
        top = ctk.CTkFrame(self.body, fg_color="transparent")
        top.grid(row=0, column=0, sticky="ew", padx=22, pady=(12, 28))
        self.label(top, "夜莺 / YEYING", 19, weight="bold").pack(side="left")
        self.router_link = ctk.CTkButton(
            top, text="夜莺 Router ↗", width=105, height=28, fg_color="transparent",
            hover_color=CARD, text_color=ACCENT, font=(FONT, 12),
            command=lambda: webbrowser.open("https://router.yeying.pub"),
        )
        self.router_link.pack(side="right")

        hero = ctk.CTkFrame(self.body, fg_color="transparent")
        hero.grid(row=1, column=0, sticky="ew", padx=22)
        self.label(hero, ">_", 27, ACCENT, "bold").pack()
        self.label(hero, "一键接入夜莺 Router", 29, weight="bold").pack(pady=(7, 5))
        self.label(hero, "填入自己的 API Key，自动完成 Codex 配置。", 14, MUTED).pack()

        targets = ctk.CTkFrame(self.body, fg_color="transparent")
        targets.grid(row=2, column=0, sticky="ew", padx=22, pady=(28, 18))
        self.label(targets, "你想在哪里使用 Codex？", 15, weight="bold").pack(anchor="w", pady=(0, 10))
        cards = ctk.CTkFrame(targets, fg_color="transparent")
        cards.pack(fill="x")
        cards.grid_columnconfigure((0, 1, 2), weight=1, uniform="target")
        for col, (title, detail) in enumerate([
            ("Codex App", "独立桌面应用 · 推荐"),
            ("Codex CLI", "Windows 本机终端"),
            ("VS Code 插件", "Windows 本机 Codex"),
        ]):
            button = ctk.CTkButton(
                cards, text=f"{title}\n{detail}", font=(FONT, 12),
                height=83, corner_radius=14, border_width=1,
                border_color=ACCENT if col == 0 else BORDER,
                fg_color="#24283E" if col == 0 else CARD,
                hover_color="#2C3041", text_color=TEXT,
                command=lambda t=title: self.select_target(t),
            )
            button.grid(row=0, column=col, sticky="ew", padx=(0 if col == 0 else 8, 0))
            self.buttons[title] = button

        panel = ctk.CTkFrame(self.body, fg_color=CARD, corner_radius=16, border_width=1, border_color=BORDER)
        panel.grid(row=3, column=0, sticky="ew", padx=22)
        panel.grid_columnconfigure(0, weight=1)
        self.label(panel, "夜莺 Router API Key", 14, weight="bold").grid(row=0, column=0, sticky="w", padx=18, pady=(17, 8))
        entry_row = ctk.CTkFrame(panel, fg_color="transparent")
        entry_row.grid(row=1, column=0, sticky="ew", padx=18)
        entry_row.grid_columnconfigure(0, weight=1)
        self.key_entry = ctk.CTkEntry(
            entry_row, textvariable=self.key_var, show="●", height=43,
            placeholder_text="粘贴你的夜莺 API Key", fg_color=BG,
            border_color=BORDER, font=(FONT, 13),
        )
        self.key_entry.grid(row=0, column=0, sticky="ew")
        self.show_button = ctk.CTkButton(
            entry_row, text="显示", width=54, height=39, fg_color="transparent",
            hover_color="#303545", text_color=MUTED, font=(FONT, 12), command=self.toggle_key,
        )
        self.show_button.grid(row=0, column=1, padx=(4, 0))
        self.label(panel, core.BASE_URL, 12, ACCENT).grid(row=2, column=0, sticky="w", padx=18, pady=(12, 0))
        model_row = ctk.CTkFrame(panel, fg_color="transparent")
        model_row.grid(row=3, column=0, sticky="ew", padx=18, pady=(10, 15))
        model_row.grid_columnconfigure(1, weight=1)
        self.label(model_row, "模型", 12, MUTED).grid(row=0, column=0, padx=(0, 10))
        self.model_box = ctk.CTkComboBox(
            model_row, variable=self.model_var, values=list(core.BUILTIN_MODELS), height=35,
            fg_color=BG, border_color=BORDER, button_color=BORDER,
            font=(FONT, 12), dropdown_font=(FONT, 12),
        )
        self.model_box.grid(row=0, column=1, sticky="ew")

        path_panel = ctk.CTkFrame(self.body, fg_color="transparent")
        path_panel.grid(row=4, column=0, sticky="ew", padx=22, pady=(17, 10))
        path_panel.grid_columnconfigure(0, weight=1)
        self.path_status_label = self.label(path_panel, "", 12, MUTED)
        self.path_status_label.grid(row=0, column=0, sticky="w")
        self.path_label = self.label(path_panel, "", 11, MUTED, justify="left", anchor="w", wraplength=410)
        self.path_label.grid(row=1, column=0, sticky="w", pady=(3, 0))
        self.path_settings_button = ctk.CTkButton(
            path_panel, text="高级设置 ▸", width=90, height=27, fg_color="transparent", hover_color=CARD,
            text_color=MUTED, font=(FONT, 11), command=self.toggle_path_settings,
        )
        self.path_settings_button.grid(row=0, column=1, padx=(7, 0))
        self.path_advanced = ctk.CTkFrame(path_panel, fg_color="transparent")
        self.choose_path_button = ctk.CTkButton(
            self.path_advanced, text="更改配置位置", width=115, height=30, fg_color=CARD,
            hover_color=BORDER, text_color=ACCENT, font=(FONT, 12), command=self.choose_file,
        )
        self.choose_path_button.pack(side="left")
        self.auto_path_button = ctk.CTkButton(
            self.path_advanced, text="恢复自动定位", width=115, height=30, fg_color=CARD,
            hover_color=BORDER, text_color=ACCENT, font=(FONT, 12), command=self.use_automatic_path,
        )
        self.auto_path_button.pack(side="left", padx=(8, 0))

        self.apply_button = ctk.CTkButton(
            self.body, text="应用配置", height=47, corner_radius=12,
            font=(FONT, 16, "bold"), fg_color=ACCENT, hover_color="#777FE8",
            text_color="#111323", command=self.apply_config,
        )
        self.apply_button.grid(row=5, column=0, sticky="ew", padx=22, pady=(6, 15))
        self.status_label = self.label(self.body, "", 12, MUTED,
                                       wraplength=500, justify="left", anchor="w")

    def select_target(self, target):
        self.target = target
        for name, button in self.buttons.items():
            button.configure(border_color=ACCENT if name == target else BORDER,
                             fg_color="#24283E" if name == target else CARD)

    def toggle_key(self):
        showing = self.key_entry.cget("show") == ""
        self.key_entry.configure(show="●" if showing else "")
        self.show_button.configure(text="显示" if showing else "隐藏")

    def refresh_path(self):
        if self.path is None:
            title, detail = "无法自动定位配置", "请展开高级设置，检查配置位置。"
        elif self.auto_path:
            exists = self.path.exists()
            title = "已自动定位配置" if exists else "已自动确定配置位置"
            detail = str(self.path) + ("" if exists else "\n首次使用，保存时会自动创建。")
        else:
            title, detail = "自定义配置位置", str(self.path)
        self.path_status_label.configure(text=title)
        self.path_label.configure(text=detail)
        if self.path_error:
            self.set_status(self.path_error, error=True)

    def toggle_path_settings(self):
        self.path_settings_open = not self.path_settings_open
        self.path_settings_button.configure(text="高级设置 ▾" if self.path_settings_open else "高级设置 ▸")
        if self.path_settings_open:
            self.path_advanced.grid(row=2, column=0, columnspan=2, sticky="w", pady=(9, 0))
        else:
            self.path_advanced.grid_remove()

    def use_automatic_path(self):
        self.auto_path = True
        try:
            self.path = core.config_path()
            self.path_error = ""
        except core.ConfigError as exc:
            self.path = None
            self.path_error = str(exc)
        self.refresh_path()
        if self.path:
            self.load_model()
            self.set_status("已恢复自动定位，填入 Key 后即可应用配置。")

    def load_model(self):
        try:
            selected = core.configured_model(self.path) if self.path else core.MODEL
            self.model_var.set(selected)
            self.model_box.configure(values=list(dict.fromkeys([selected, *core.BUILTIN_MODELS])))
        except core.ConfigError as exc:
            self.set_status(str(exc), error=True)

    def choose_file(self):
        chosen = filedialog.asksaveasfilename(
            parent=self, title="选择 Codex 的 config.toml（也可新建）", defaultextension=".toml",
            initialfile="config.toml", initialdir=str(self.path.parent) if self.path and self.path.parent.exists() else None,
            filetypes=[("Codex 配置", "*.toml")], confirmoverwrite=False,
        )
        if chosen:
            self.path = Path(chosen)
            self.auto_path = False
            self.path_error = ""
            self.refresh_path()
            self.load_model()
            self.set_status("已选择配置文件；请确认这是 Codex 设置中打开的那一份。")

    def set_status(self, text, *, error=False, success=False):
        self.status_label.configure(text=text, text_color="#FF9CA8" if error else "#82D8B3" if success else MUTED)
        self.status_label.grid(row=6, column=0, sticky="ew", padx=22, pady=(0, 12))

    def apply_config(self):
        if self.path is None:
            self.set_status("无法自动定位配置，请在高级设置中检查配置位置。", error=True)
            return
        self.apply_button.configure(state="disabled")
        try:
            plan = core.prepare(self.path, self.key_var.get(), self.model_var.get())
            changed = core.apply(plan)
            self.key_var.set("")
            self.key_entry.configure(show="●")
            self.show_button.configure(text="显示")
            self.set_status(
                (f"配置已保存，模型：{self.model_var.get().strip()}。" if changed else "已是这份夜莺配置，无需重复保存。") +
                "请完全退出并重开 Codex，再新建对话。\n" + " ".join(plan.notices), success=True,
            )
        except core.ConfigError as exc:
            self.set_status(str(exc), error=True)
        except OSError:
            self.set_status("文件操作失败，请检查目录权限和磁盘空间。", error=True)
        except Exception:
            # Never format unexpected exceptions: parser errors may quote secrets.
            self.set_status("本次操作未完成。请保留原配置和备份，重新检查后再试。", error=True)
        finally:
            self.apply_button.configure(state="normal")
            self.refresh_path()


def main():
    parser = argparse.ArgumentParser(description="夜莺 Codex 配置器")
    # Diagnostic path is opt-in, so UI testing never falls back to real user config.
    parser.add_argument("--config", type=Path)
    parser.add_argument("--ui-check", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--self-test", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    ctk.set_appearance_mode("dark")
    ctk.set_default_color_theme("blue")
    if os.name == "nt":
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Yeying.CodexConfigurator")
    if args.self_test:
        args.self_test.mkdir(parents=True, exist_ok=True)
        if args.config:
            raise SystemExit("--self-test chooses an isolated config path")
        if (args.self_test / "config.toml").exists() or (args.self_test / "auth.json").exists():
            raise SystemExit("--self-test requires an unused directory")
        # Exercise real auto-discovery while keeping it inside the isolated test home.
        os.environ["CODEX_HOME"] = str(args.self_test.absolute())
    app = Configurator(args.config)
    if args.self_test:
        def self_test():
            import json
            from unittest.mock import patch
            import tomllib
            result = {"version": core.VERSION, "passed": False, "scope": "isolated GUI apply, repeat, restore; no network calls"}
            try:
                assert app.auto_path and app.path == args.self_test.absolute() / "config.toml"
                assert not app.path_settings_open and not app.path_advanced.winfo_manager()
                assert app.path_status_label.cget("text") == "已自动确定配置位置"
                # First run: no picker and no existing file, just Key then Apply.
                app.key_var.set("test-only-not-a-real-key")
                app.apply_button.invoke()
                assert tomllib.loads(app.path.read_text("utf-8"))["model_provider"] == core.PROVIDER
                assert app.path_status_label.cget("text") == "已自动定位配置"
                core.restore(app.path)
                assert not app.path.exists()
                app.path_settings_button.invoke()
                assert app.path_settings_open and app.path_advanced.winfo_manager() == "grid"
                manual = args.self_test.absolute() / "manual" / "config.toml"
                with patch.object(filedialog, "asksaveasfilename", return_value=str(manual)):
                    app.choose_path_button.invoke()
                assert app.path == manual and not app.auto_path
                app.auto_path_button.invoke()
                assert app.auto_path and app.path == args.self_test.absolute() / "config.toml"
                app.path_settings_button.invoke()
                assert not app.path_settings_open and not app.path_advanced.winfo_manager()
                original = '# GUI test fixture\nmodel="gpt-5.6-sol"\n[desktop]\nkeep=true\n[mcp_servers.demo]\ncommand="keep"\n'
                app.path.write_text(original, encoding="utf-8")
                assert app.key_var.get() == ""
                assert all(model in app.model_box.cget("values") for model in core.BUILTIN_MODELS)
                assert not hasattr(app, "fetch_button")
                app.load_model()
                assert app.model_var.get() == "gpt-5.6-sol"
                assert "gpt-5.6-sol" in app.model_box.cget("values")
                # Save each real built-in choice through the GUI, without contacting a model.
                for model in core.BUILTIN_MODELS:
                    app.model_box.set(model)
                    app.key_var.set("test-only-not-a-real-key")
                    app.apply_button.invoke()
                    parsed = tomllib.loads(app.path.read_text("utf-8"))
                    assert parsed["model"] == model
                    assert app.key_var.get() == ""
                    core.restore(app.path)
                    assert app.path.read_text("utf-8") == original
                    assert not (app.path.parent / "auth.json").exists()
                # The editable combobox must also accept a model absent from the list.
                chosen = "custom/test-model-manual"
                app.model_var.set(chosen)
                app.key_var.set("test-only-not-a-real-key")
                app.apply_button.invoke()
                parsed = tomllib.loads(app.path.read_text("utf-8"))
                assert parsed["model_provider"] == "yeying"
                assert parsed["model"] == chosen
                assert parsed["model_providers"]["yeying"]["base_url"] == core.BASE_URL
                assert parsed["desktop"]["keep"] is True
                assert parsed["mcp_servers"]["demo"]["command"] == "keep"
                assert app.key_var.get() == ""
                assert core.can_restore(app.path)
                app.select_target("VS Code 插件")
                app.select_target("Codex CLI")
                app.select_target("Codex App")
                backup_count = len(list(core.backup_root(app.path).glob("*.dpapi")))
                app.key_var.set("test-only-not-a-real-key")
                app.apply_button.invoke()
                assert len(list(core.backup_root(app.path).glob("*.dpapi"))) == backup_count
                core.restore(app.path)
                assert app.path.read_text("utf-8") == original
                assert not (app.path.parent / "auth.json").exists()
                assert not core.can_restore(app.path)
                result["passed"] = True
                result["checks"] = ["built-in models available without Key", "no fetch button", "existing model preserved", "all five preset models saved", "custom model saved", "model and URL", "desktop and MCP preserved", "key field cleared", "target selectors", "idempotence", "DPAPI backup and recovery"]
                result["checks"] += ["automatic CODEX_HOME discovery", "first run saved without file picker", "advanced settings hidden by default", "manual override and return to auto"]
                result["models"] = list(core.BUILTIN_MODELS)
                app.set_status("界面自检通过：配置、保留原设置、备份和恢复均正常。", success=True)
            except Exception:
                result["error"] = "GUI self-test failed; inspect isolated fixture"
                app.set_status("界面自检未通过，请检查隔离测试文件。", error=True)
            (args.self_test / "self-test.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
            if not args.ui_check:
                app.after(500, app.destroy)
        app.after(300, self_test)
    if args.ui_check:
        if not args.config and not args.self_test:
            raise SystemExit("--ui-check requires --config")
        def screenshot():
            app.update_idletasks()
            hwnd = ctypes.windll.user32.GetParent(app.winfo_id())
            capture_window(hwnd, args.ui_check)
            app.after(300, app.destroy)
        app.after(1800, screenshot)
    app.mainloop()


class wintypes_rect(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long), ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


def capture_window(hwnd, output: Path):
    """Capture only this tool's window, including when another app covers it."""
    from PIL import Image
    user = ctypes.WinDLL("user32", use_last_error=True)
    gdi = ctypes.WinDLL("gdi32", use_last_error=True)
    user.GetWindowDC.argtypes = [wintypes.HWND]
    user.GetWindowDC.restype = wintypes.HDC
    user.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
    user.PrintWindow.argtypes = [wintypes.HWND, wintypes.HDC, wintypes.UINT]
    gdi.CreateCompatibleDC.argtypes = [wintypes.HDC]
    gdi.CreateCompatibleDC.restype = wintypes.HDC
    gdi.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
    gdi.CreateCompatibleBitmap.restype = wintypes.HBITMAP
    gdi.SelectObject.argtypes = [wintypes.HDC, wintypes.HANDLE]
    gdi.SelectObject.restype = wintypes.HANDLE
    gdi.DeleteObject.argtypes = [wintypes.HANDLE]
    gdi.DeleteDC.argtypes = [wintypes.HDC]
    gdi.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                            ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
    rect = wintypes_rect()
    user.GetWindowRect(hwnd, ctypes.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    source = user.GetWindowDC(hwnd)
    target = gdi.CreateCompatibleDC(source)
    bitmap = gdi.CreateCompatibleBitmap(source, width, height)
    previous = gdi.SelectObject(target, bitmap)
    try:
        if not user.PrintWindow(hwnd, target, 2):
            raise RuntimeError("Window-only capture failed")
        gdi.SelectObject(target, previous)
        previous = None
        # BITMAPINFOHEADER + one RGBQUAD; negative height gives top-down rows.
        import struct
        info = ctypes.create_string_buffer(struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 32, 0, 0, 0, 0, 0, 0) + b"\0" * 4)
        pixels = ctypes.create_string_buffer(width * height * 4)
        if gdi.GetDIBits(source, bitmap, 0, height, pixels, info, 0) != height:
            raise RuntimeError("Window-only capture could not read pixels")
        Image.frombuffer("RGB", (width, height), pixels.raw, "raw", "BGRX", 0, 1).save(output)
    finally:
        if previous:
            gdi.SelectObject(target, previous)
        gdi.DeleteObject(bitmap)
        gdi.DeleteDC(target)
        user.ReleaseDC(hwnd, source)


if __name__ == "__main__":
    main()
