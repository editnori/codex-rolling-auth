"""Modal screens: profile naming, confirmation, and captured output."""

from __future__ import annotations

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, Static


def _profile_name_error(value: str) -> str:
    if not value:
        return "Enter a profile name."
    if any(
        not (char.isascii() and (char.isalnum() or char in "._-"))
        for char in value
    ):
        return "Use only A-Z, a-z, 0-9, dot, underscore, or dash."
    return ""


class ProfileNameModal(ModalScreen[str | None]):
    """Collect a shell-safe name for the current live auth."""

    BINDINGS = [Binding("escape", "cancel", "Cancel", show=False)]

    def compose(self) -> ComposeResult:
        with Vertical(classes="modal-box"):
            yield Label("Save current auth", classes="modal-title")
            yield Static(
                "Name the Codex session currently stored in auth.json.",
                classes="modal-body",
            )
            yield Input(
                placeholder="profile name",
                id="profile-name",
                select_on_focus=False,
            )
            yield Static("Enter a profile name.", id="profile-name-error")
            with Horizontal(classes="modal-buttons"):
                yield Button("Save", id="save", disabled=True)
                yield Button("Cancel", id="cancel")
            yield Static("enter save  ·  esc cancel", classes="modal-hint")

    def on_mount(self) -> None:
        self.query_one("#profile-name", Input).focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        self._show_validation(event.value)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        event.stop()
        self._submit(event.value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "save":
            self._submit(self.query_one("#profile-name", Input).value)
        else:
            self.action_cancel()

    def _show_validation(self, value: str) -> str:
        error = _profile_name_error(value)
        self.query_one("#profile-name-error", Static).update(error)
        self.query_one("#save", Button).disabled = bool(error)
        return error

    def _submit(self, value: str) -> None:
        name = value.strip()
        if self._show_validation(name):
            return
        self.dismiss(name)

    def action_cancel(self) -> None:
        self.dismiss(None)


class ConfirmModal(ModalScreen[bool]):
    """Yes/No confirmation. Dismisses with True only on explicit confirm."""

    BINDINGS = [
        Binding("y", "confirm", "Yes", show=False),
        Binding("n,escape", "cancel", "No", show=False),
        Binding("left", "app.focus_previous", show=False),
        Binding("right", "app.focus_next", show=False),
    ]

    def __init__(
        self,
        message: str,
        *,
        title: str = "Confirm",
        yes_label: str = "Yes",
        default_cancel: bool = False,
    ) -> None:
        super().__init__()
        self._title = title
        self._message = message
        self._yes_label = yes_label
        self._default_cancel = default_cancel

    def compose(self) -> ComposeResult:
        with Vertical(classes="modal-box"):
            yield Label(self._title, classes="modal-title")
            yield Static(self._message, classes="modal-body")
            with Horizontal(classes="modal-buttons"):
                yield Button(self._yes_label, id="yes")
                yield Button("Cancel", id="no")
            yield Static(
                f"← → · enter  ·  y {self._yes_label.lower()}  ·  n / esc cancel",
                classes="modal-hint",
            )

    def on_mount(self) -> None:
        if self._default_cancel:
            self.query_one("#no", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)


class OutputModal(ModalScreen[None]):
    """Scrollable display of captured (ANSI-colored) action output."""

    BINDINGS = [Binding("escape,q,enter", "dismiss_modal", "Close", show=False)]

    def __init__(self, title: str, output: str) -> None:
        super().__init__()
        self._title = title
        self._output = output

    def compose(self) -> ComposeResult:
        with Vertical(classes="modal-box modal-box-wide"):
            yield Label(self._title, classes="modal-title")
            with VerticalScroll(classes="modal-output"):
                yield Static(Text.from_ansi(self._output.rstrip() or "(no output)"))
            with Horizontal(classes="modal-buttons"):
                yield Button("Close", id="close")
            yield Static("esc close", classes="modal-hint")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(None)

    def action_dismiss_modal(self) -> None:
        self.dismiss(None)
