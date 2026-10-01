// Cloud Backup in the top bar: an icon that says whether a backup is
// running (the cloud with an arrow going up), and a menu with the backup in
// progress or the last one, "Back Up Now" and the Cloud Backup app.
//
// It only reads what the backup job (/usr/local/lib/live-backup/run-backup)
// writes in ~/.local/state/live-backup: progress.json while a backup runs
// (restic's progress, rewritten every second, removed at the end) and
// status.json once it's over. It watches that folder, so it changes as soon
// as they do; a progress file left behind by a job that died is ignored
// once it's old. It's shown only once the backups are set up
// (~/.config/live-backup/config.json).

import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import St from 'gi://St';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as BarLevel from 'resource:///org/gnome/shell/ui/barLevel.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const HOME = GLib.get_home_dir();
const STATE_DIR = GLib.build_filenamev([HOME, '.local/state/live-backup']);
const CONFIG_DIR = GLib.build_filenamev([HOME, '.config/live-backup']);
const APP_ID = 'org.ubuntu.LiveBackup.desktop';
const STALE = 180; // seconds without progress: the job isn't running any more

const PROVIDERS = {
    google: 'Google Drive', onedrive: 'OneDrive', dropbox: 'Dropbox', nextcloud: 'Nextcloud',
    icloud: 'iCloud Drive', samba: 'Samba', sftp: 'SFTP',
};

const STRINGS = {
    en: {
        preparing: 'Getting ready to back up…', backup: 'Backing up — %d%%',
        cleaning: 'Cleaning up old versions…', uploading: 'Sending to iCloud Drive…',
        files: '%s of %s files', remaining: 'about %s left', saved: '%s files, %s',
        never: 'No backup yet', last_ok: 'Last backup: %s', last_failed: 'The last backup failed',
        today: 'today at %s', yesterday: 'yesterday at %s',
        now: 'Back Up Now', open: 'Open Cloud Backup',
        minutes: '%d min', hours: '%d h', seconds: 'a few seconds',
    },
    it: {
        preparing: 'Preparazione del backup…', backup: 'Backup in corso — %d%%',
        cleaning: 'Pulizia delle versioni vecchie…', uploading: 'Invio a iCloud Drive…',
        files: '%s di %s file', remaining: 'circa %s alla fine', saved: '%s file, %s',
        never: 'Non c\'è ancora un backup', last_ok: 'Ultimo backup: %s',
        last_failed: 'L\'ultimo backup non è riuscito',
        today: 'oggi alle %s', yesterday: 'ieri alle %s',
        now: 'Esegui il backup ora', open: 'Apri Cloud Backup',
        minutes: '%d min', hours: '%d h', seconds: 'pochi secondi',
    },
};

function _(key) {
    const lang = GLib.get_language_names().map(l => l.slice(0, 2)).find(l => l in STRINGS);
    return (STRINGS[lang ?? 'en'] ?? STRINGS.en)[key] ?? STRINGS.en[key];
}

function format(template, ...values) {
    return values.reduce((text, value) => text.replace(/%[ds]/, value), template.replace('%%', '%'));
}

function readJson(dir, name) {
    try {
        const [, bytes] = GLib.file_get_contents(GLib.build_filenamev([dir, name]));
        return JSON.parse(new TextDecoder().decode(bytes));
    } catch {
        return null;
    }
}

function when(iso) {
    const time = GLib.DateTime.new_from_iso8601(iso, null)?.to_local();
    if (!time)
        return iso;
    const midnight = t => GLib.DateTime.new_local(t.get_year(), t.get_month(),
        t.get_day_of_month(), 0, 0, 0);
    const days = Math.round(
        midnight(GLib.DateTime.new_now_local()).difference(midnight(time)) / GLib.TIME_SPAN_DAY);
    const clock = time.format('%H:%M');
    if (days === 0)
        return format(_('today'), clock);
    if (days === 1)
        return format(_('yesterday'), clock);
    return time.format('%x %H:%M');
}

function duration(seconds) {
    if (seconds < 60)
        return _('seconds');
    if (seconds < 3600)
        return format(_('minutes'), Math.ceil(seconds / 60));
    return format(_('hours'), Math.round(seconds / 3600));
}

const Indicator = GObject.registerClass(
class CloudBackupIndicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.5, 'Cloud Backup');
        this._extension = extension;
        this._icon = new St.Icon({style_class: 'system-status-icon'});
        this.add_child(this._icon);

        this._title = new PopupMenu.PopupMenuItem('', {reactive: false});
        this._title.label.add_style_class_name('cloud-backup-title');
        this._detail = new PopupMenu.PopupMenuItem('', {reactive: false});
        this._detail.label.add_style_class_name('cloud-backup-detail');
        // A long message (an error) wraps instead of widening the menu
        this._detail.label.clutter_text.line_wrap = true;
        this._barItem = new PopupMenu.PopupBaseMenuItem({reactive: false});
        // The slider's look, without its handle: a progress bar, not a control
        this._bar = new BarLevel.BarLevel({style_class: 'slider cloud-backup-bar'});
        this._barItem.add_child(this._bar);
        this._where = new PopupMenu.PopupMenuItem('', {reactive: false});
        this._where.label.add_style_class_name('cloud-backup-detail');
        for (const item of [this._title, this._barItem, this._detail, this._where])
            this.menu.addMenuItem(item);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._now = this.menu.addAction(_('now'), () => this._backUpNow());
        this.menu.addAction(_('open'), () => this._openApp());

        this.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._update();
        });
        this._update();
    }

    _iconFor(name) {
        return Gio.icon_new_for_string(
            GLib.build_filenamev([this._extension.path, 'icons', `${name}-symbolic.svg`]));
    }

    _update() {
        const config = readJson(CONFIG_DIR, 'config.json');
        this.visible = config !== null;
        if (!config)
            return;
        const progress = readJson(STATE_DIR, 'progress.json');
        const status = readJson(STATE_DIR, 'status.json');
        const running = progress !== null &&
            GLib.get_real_time() / 1e6 - (progress.time ?? 0) < STALE;
        const name = PROVIDERS[config.provider] ?? '';
        this._where.label.text = config.identity ? `${name} (${config.identity})` : name;
        this._now.visible = !running;
        this._barItem.visible = running && progress.phase === 'backup';
        this._detail.label.remove_style_class_name('cloud-backup-error');

        if (running) {
            this._icon.gicon = this._iconFor('cloud-backup-active');
            if (progress.phase === 'backup') {
                const percent = Math.floor((progress.percent ?? 0) * 100);
                this._title.label.text = format(_('backup'), percent);
                this._bar.value = progress.percent ?? 0;
                const parts = [];
                if (progress.total_files) {
                    parts.push(format(_('files'), progress.files.toLocaleString(),
                        progress.total_files.toLocaleString()));
                }
                if (progress.total_bytes) {
                    parts.push(`${GLib.format_size(progress.bytes)} / ` +
                        `${GLib.format_size(progress.total_bytes)}`);
                }
                if (progress.remaining)
                    parts.push(format(_('remaining'), duration(progress.remaining)));
                this._detail.label.text = parts.join(' · ');
            } else {
                this._title.label.text = _(progress.phase) ?? _('preparing');
                this._detail.label.text = '';
            }
        } else if (status?.time && status.ok === false) {
            this._icon.gicon = this._iconFor('cloud-backup-error');
            this._title.label.text = _('last_failed');
            this._detail.label.text = `${when(status.time)} — ${status.message ?? ''}`;
            this._detail.label.add_style_class_name('cloud-backup-error');
        } else {
            this._icon.gicon = this._iconFor('cloud-backup');
            this._title.label.text = status?.time
                ? format(_('last_ok'), when(status.time)) : _('never');
            this._detail.label.text = status?.files
                ? format(_('saved'), status.files.toLocaleString(),
                    GLib.format_size(status.bytes ?? 0))
                : '';
        }
        this._detail.visible = this._detail.label.text !== '';
    }

    _backUpNow() {
        Gio.Subprocess.new(['systemctl', '--user', 'start', '--no-block', 'live-backup.service'],
            Gio.SubprocessFlags.NONE);
    }

    _openApp() {
        const app = Shell.AppSystem.get_default().lookup_app(APP_ID);
        if (app)
            app.activate();
        else
            Gio.DesktopAppInfo.new(APP_ID)?.launch([], null);
    }
});

export default class CloudBackupExtension extends Extension {
    enable() {
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
        this._monitors = [STATE_DIR, CONFIG_DIR].map(dir => {
            GLib.mkdir_with_parents(dir, 0o700);
            const monitor = Gio.File.new_for_path(dir).monitor_directory(
                Gio.FileMonitorFlags.WATCH_MOVES, null);
            monitor.connect('changed', () => this._indicator?._update());
            return monitor;
        });
        // A job that died leaves its progress behind; relative times age too
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_LOW, 30, () => {
            this._indicator?._update();
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        GLib.source_remove(this._timer);
        this._monitors.forEach(m => m.cancel());
        this._monitors = null;
        this._indicator.destroy();
        this._indicator = null;
    }
}
