import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/activity.dart';
import '../models/bookmark.dart';
import '../models/trail.dart';

/// Local-first storage for trails, backed by a plain SQLite table.
/// Path and cue geometry are kept as JSON text columns for simplicity.
class TrailStore {
  TrailStore._();
  static final TrailStore instance = TrailStore._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'trailguide.db'),
      version: 11,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE trails (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            region_id TEXT NOT NULL DEFAULT 'coquitlam',
            color TEXT NOT NULL DEFAULT '#1565C0',
            path TEXT NOT NULL,
            anchors TEXT NOT NULL DEFAULT '[]',
            cues TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            walked_meters REAL NOT NULL DEFAULT 0,
            walk_count INTEGER NOT NULL DEFAULT 0,
            elev_gain REAL NOT NULL DEFAULT 0
          )
        ''');
        await _createActivities(db);
        await _createWalkProgress(db);
        await _createRecordingProgress(db);
        await _createBookmarks(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              "ALTER TABLE trails ADD COLUMN region_id TEXT NOT NULL DEFAULT 'coquitlam'");
        }
        if (oldVersion < 3) {
          await db.execute(
              "ALTER TABLE trails ADD COLUMN anchors TEXT NOT NULL DEFAULT '[]'");
        }
        if (oldVersion < 4) {
          await db.execute(
              "ALTER TABLE trails ADD COLUMN color TEXT NOT NULL DEFAULT '#1565C0'");
        }
        if (oldVersion < 5) {
          await db.execute(
              'ALTER TABLE trails ADD COLUMN walked_meters REAL NOT NULL DEFAULT 0');
          await db.execute(
              'ALTER TABLE trails ADD COLUMN walk_count INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 6) {
          await db.execute(
              'ALTER TABLE trails ADD COLUMN elev_gain REAL NOT NULL DEFAULT 0');
        }
        if (oldVersion < 7) {
          await _createActivities(db);
        }
        if (oldVersion < 8) {
          await _createWalkProgress(db);
        }
        if (oldVersion < 9) {
          await _createRecordingProgress(db);
        }
        if (oldVersion < 10) {
          // Creates the table fresh, already including icon_code_point (see
          // below) — so the >= 10 guard on that migration is what stops this
          // path from then trying to add the same column a second time.
          await _createBookmarks(db);
        }
        if (oldVersion >= 10 && oldVersion < 11) {
          // Only a v10 install (bookmarks shipped without icon_code_point)
          // needs this — anything older got the column for free above.
          await db.execute(
              'ALTER TABLE bookmarks ADD COLUMN icon_code_point INTEGER');
        }
      },
    );
    return _db!;
  }

  static Future<void> _createBookmarks(Database db) async {
    await db.execute('''
      CREATE TABLE bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'other',
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        icon_code_point INTEGER
      )
    ''');
  }

  static Future<void> _createActivities(Database db) async {
    await db.execute('''
      CREATE TABLE activities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        trail_id INTEGER,
        trail_name TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        duration_sec INTEGER NOT NULL,
        distance_meters REAL NOT NULL,
        elev_gain_meters REAL NOT NULL,
        track TEXT
      )
    ''');
  }

  /// One row per in-progress walk, keyed by trail — only one walk is ever
  /// active, so this also caps it to a single checkpoint. See [WalkCheckpoint].
  static Future<void> _createWalkProgress(Database db) async {
    await db.execute('''
      CREATE TABLE walk_progress (
        trail_id INTEGER PRIMARY KEY,
        trail_name TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        paused_total_sec INTEGER NOT NULL DEFAULT 0,
        was_paused INTEGER NOT NULL DEFAULT 0,
        next_index INTEGER NOT NULL DEFAULT 0,
        walked_meters REAL NOT NULL DEFAULT 0,
        elev_gain_meters REAL NOT NULL DEFAULT 0,
        last_lat REAL,
        last_lng REAL,
        track TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  Future<List<Trail>> all() async {
    final db = await _database;
    final rows = await db.query('trails', orderBy: 'created_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<Trail> save(Trail t) async {
    final db = await _database;
    final values = {
      'name': t.name,
      'region_id': t.regionId,
      'color': t.color,
      'path': t.pathToJson(),
      'anchors': t.anchorsToJson(),
      'cues': t.cuesToJson(),
      'created_at': t.createdAt.millisecondsSinceEpoch,
    };
    if (t.id == null) {
      t.id = await db.insert('trails', values);
    } else {
      await db.update('trails', values, where: 'id = ?', whereArgs: [t.id]);
    }
    return t;
  }

  /// Name search for the map search feature. Skips [_fromRow]'s cue parsing
  /// (irrelevant for a results list) and derives each hit's jump-to point —
  /// the first anchor (trailhead the author placed), falling back to the
  /// first path point for legacy trails saved before anchors existed.
  Future<List<({int id, String name, LatLng? position})>> searchByName(
      String query) async {
    final db = await _database;
    final rows = await db.query(
      'trails',
      columns: ['id', 'name', 'path', 'anchors'],
      where: 'name LIKE ?',
      whereArgs: ['%$query%'],
      limit: 20,
    );
    return [
      for (final r in rows)
        (
          id: r['id'] as int,
          name: r['name'] as String,
          position: _jumpPoint(r),
        ),
    ];
  }

  LatLng? _jumpPoint(Map<String, Object?> r) {
    final anchors = Trail.pathFromJson((r['anchors'] as String?) ?? '[]');
    if (anchors.isNotEmpty) return anchors.first;
    final path = Trail.pathFromJson(r['path'] as String);
    return path.isNotEmpty ? path.first : null;
  }

  Future<void> delete(int id) async {
    final db = await _database;
    await db.delete('trails', where: 'id = ?', whereArgs: [id]);
  }

  /// Inserts a trail from a backup, preserving its walk stats (unlike [save],
  /// which leaves stats to [recordWalk]).
  Future<void> restoreTrail(Trail t) async {
    final db = await _database;
    await db.insert('trails', {
      'name': t.name,
      'region_id': t.regionId,
      'color': t.color,
      'path': t.pathToJson(),
      'anchors': t.anchorsToJson(),
      'cues': t.cuesToJson(),
      'created_at': t.createdAt.millisecondsSinceEpoch,
      'walked_meters': t.walkedMeters,
      'walk_count': t.walkCount,
      'elev_gain': t.elevGainMeters,
    });
  }

  /// Adds [meters] to a trail's lifetime total and bumps its walk count. Kept
  /// separate from [save] so recording a walk never collides with an edit.
  Future<void> recordWalk(int id, double meters, double elevGain) async {
    final db = await _database;
    await db.rawUpdate(
      'UPDATE trails SET walked_meters = walked_meters + ?, '
      'walk_count = walk_count + 1, elev_gain = elev_gain + ? WHERE id = ?',
      [meters, elevGain, id],
    );
  }

  /// Logs a completed walk and returns it with its assigned id.
  Future<Activity> addActivity(Activity a) async {
    final db = await _database;
    a.id = await db.insert('activities', a.toRow());
    return a;
  }

  /// All logged walks, newest first.
  Future<List<Activity>> activities() async {
    final db = await _database;
    final rows = await db.query('activities', orderBy: 'started_at DESC');
    return rows.map(Activity.fromRow).toList();
  }

  Future<void> deleteActivity(int id) async {
    final db = await _database;
    await db.delete('activities', where: 'id = ?', whereArgs: [id]);
  }

  /// Upserts the in-progress-walk checkpoint for [c.trailId].
  Future<void> saveWalkCheckpoint(WalkCheckpoint c) async {
    final db = await _database;
    await db.insert('walk_progress', c.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The single active walk checkpoint, if any (only one walk is ever active).
  Future<WalkCheckpoint?> loadWalkCheckpoint() async {
    final db = await _database;
    final rows = await db.query('walk_progress', limit: 1);
    if (rows.isEmpty) return null;
    return WalkCheckpoint.fromRow(rows.first);
  }

  Future<void> clearWalkCheckpoint(int trailId) async {
    final db = await _database;
    await db.delete('walk_progress', where: 'trail_id = ?', whereArgs: [trailId]);
  }

  /// One row, no key needed — only one recording can ever be in progress.
  static Future<void> _createRecordingProgress(Database db) async {
    await db.execute('''
      CREATE TABLE recording_progress (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        region_id TEXT NOT NULL DEFAULT 'coquitlam',
        started_at INTEGER NOT NULL,
        paused_total_sec INTEGER NOT NULL DEFAULT 0,
        was_paused INTEGER NOT NULL DEFAULT 0,
        walked_meters REAL NOT NULL DEFAULT 0,
        elev_gain_meters REAL NOT NULL DEFAULT 0,
        path TEXT NOT NULL,
        track TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// Upserts the single in-progress-recording checkpoint.
  Future<void> saveRecordingCheckpoint(RecordingCheckpoint c) async {
    final db = await _database;
    await db.insert('recording_progress', {'id': 1, ...c.toRow()},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<RecordingCheckpoint?> loadRecordingCheckpoint() async {
    final db = await _database;
    final rows = await db.query('recording_progress', limit: 1);
    if (rows.isEmpty) return null;
    return RecordingCheckpoint.fromRow(rows.first);
  }

  Future<void> clearRecordingCheckpoint() async {
    final db = await _database;
    await db.delete('recording_progress');
  }

  /// All saved bookmarks, newest first.
  Future<List<Bookmark>> allBookmarks() async {
    final db = await _database;
    final rows = await db.query('bookmarks', orderBy: 'created_at DESC');
    return rows.map(_bookmarkFromRow).toList();
  }

  Future<Bookmark> saveBookmark(Bookmark b) async {
    final db = await _database;
    final values = {
      'name': b.name,
      'category': b.category.name,
      'lat': b.position.latitude,
      'lng': b.position.longitude,
      'note': b.note,
      'created_at': b.createdAt.millisecondsSinceEpoch,
      'icon_code_point': b.icon.codePoint,
    };
    if (b.id == null) {
      b.id = await db.insert('bookmarks', values);
    } else {
      await db.update('bookmarks', values, where: 'id = ?', whereArgs: [b.id]);
    }
    return b;
  }

  Future<void> deleteBookmark(int id) async {
    final db = await _database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  Bookmark _bookmarkFromRow(Map<String, Object?> r) {
    final category = BookmarkCategory.values.firstWhere(
      (c) => c.name == r['category'] as String,
      orElse: () => BookmarkCategory.other,
    );
    return Bookmark(
      id: r['id'] as int,
      name: r['name'] as String,
      category: category,
      position: LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble()),
      icon: iconForCodePoint(r['icon_code_point'] as int?, category.icon),
      note: (r['note'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    );
  }

  Trail _fromRow(Map<String, Object?> r) {
    final path = Trail.pathFromJson(r['path'] as String);
    return Trail(
      id: r['id'] as int,
      name: r['name'] as String,
      regionId: (r['region_id'] as String?) ?? 'coquitlam',
      color: (r['color'] as String?) ?? '#1565C0',
      path: path,
      anchors: Trail.pathFromJson((r['anchors'] as String?) ?? '[]'),
      cues: Trail.cuesFromJson(r['cues'] as String, path: path),
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      walkedMeters: (r['walked_meters'] as num?)?.toDouble() ?? 0,
      walkCount: (r['walk_count'] as int?) ?? 0,
      elevGainMeters: (r['elev_gain'] as num?)?.toDouble() ?? 0,
    );
  }
}
