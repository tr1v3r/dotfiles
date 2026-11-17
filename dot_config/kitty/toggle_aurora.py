"""Toggle Kitty's complete built-in aurora without writing configuration."""

from kittens.tui.handler import result_handler
from kitty.config import load_config
from kitty.fast_data_types import get_options


def main(args):
    pass


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    opts = get_options()
    shaders = list(opts.custom_shaders)
    if 'northern-lights' in shaders:
        shaders.remove('northern-lights')
    else:
        shaders.insert(0, 'northern-lights')
    # Reparse fresh keymap definitions: runtime key definitions are consumed
    # after application, so directly reapplying get_options() breaks macOS keys.
    overrides = tuple(
        line for line in opts.config_overrides
        if line.split(maxsplit=1)[:1] != ['custom_shaders']
    )
    fresh = load_config(*opts.all_config_paths, overrides=overrides)
    # Keep other shaders (e.g. Lightning) active when aurora is disabled.
    # _replace() drops parsed keymap/config metadata; modify the fresh options.
    fresh.custom_shaders = tuple(shaders)
    boss.apply_new_options(fresh)
