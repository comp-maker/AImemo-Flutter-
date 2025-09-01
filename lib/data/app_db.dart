import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_db.g.dart';

// 메모 테이블
class Memos extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withDefault(const Constant('제목 없음'))();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// 퀴즈 테이블 (생성된 문제 JSON 저장)
@DataClassName('Quiz')  
class Quizzes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get memoId => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get questionsJson => text()();
}

// 풀이 테이블 (사용자 선택/점수 저장)
class Attempts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get quizId => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get answersJson => text()();
  IntColumn get score => integer()();
}

@DriftDatabase(tables: [Memos, Quizzes, Attempts])
class AppDb extends _$AppDb {
  AppDb() : super(_open());

  // ⚠️ 개발 중 테이블을 추가했다면 마이그레이션을 해야 합니다.
  // 간단히는 schemaVersion을 올리고 아래 migration 로직에서 새 테이블을 생성합니다.
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 -> v2: Quizzes, Attempts 테이블 신설
          if (from < 2) {
            await m.createTable(quizzes);
            await m.createTable(attempts);
          }
        },
      );

  // ---- 메모 CRUD ----
  Future<int> addMemo(String title, String content) =>
      into(memos).insert(MemosCompanion.insert(
        title: Value(title.isEmpty ? '제목 없음' : title),
        content: content,
      ));

  Future<List<Memo>> listMemos() =>
      (select(memos)..orderBy([(m) => OrderingTerm.desc(m.updatedAt)])).get();

  Future<Memo?> getMemo(int id) =>
      (select(memos)..where((m) => m.id.equals(id))).getSingleOrNull();

  Future<int> updateTitle(int id, String title) =>
      (update(memos)..where((m) => m.id.equals(id))).write(
        MemosCompanion(
          title: Value(title.isEmpty ? '제목 없음' : title),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<int> updateContent(int id, String content) =>
      (update(memos)..where((m) => m.id.equals(id))).write(
        MemosCompanion(
          content: Value(content),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<int> deleteMemo(int id) =>
      (delete(memos)..where((m) => m.id.equals(id))).go();

  // ---- 퀴즈 ----
  Future<int> addQuiz(int memoId, String questionsJson) =>
      into(quizzes).insert(
        QuizzesCompanion.insert(memoId: memoId, questionsJson: questionsJson),
      );

  Future<List<Quiz>> listQuizzesForMemo(int memoId) =>
      (select(quizzes)
            ..where((q) => q.memoId.equals(memoId))
            ..orderBy([(q) => OrderingTerm.desc(q.createdAt)]))
          .get();

  // ---- 풀이 ----
  Future<int> addAttempt(int quizId, String answersJson, int score) =>
      into(attempts).insert(
        AttemptsCompanion.insert(
          quizId: quizId,
          answersJson: answersJson,
          score: score,
        ),
      );

  Future<List<Attempt>> listAttemptsForQuiz(int quizId) =>
      (select(attempts)..where((a) => a.quizId.equals(quizId))).get();
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'memoquiz.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
