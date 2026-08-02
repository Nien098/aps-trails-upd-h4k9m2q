import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/activity.dart';
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
      version: 7,
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
      },
    );
    return _db!;
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
