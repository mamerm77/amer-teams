import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Language and direction (docs/ARABIC.md). Arabic mirrors the whole layout right to left and translates Flutter's
/// own widgets (dates, pickers, menus); the app's own text is translated through [t] as coverage grows.
class AppLocale extends ChangeNotifier {
  AppLocale._();
  static final instance = AppLocale._();
  String mode = 'system';                                         // system | en | ar
  Locale? get locale => mode == 'system' ? null : Locale(mode);
  bool arabic(BuildContext c) => Localizations.localeOf(c).languageCode == 'ar';
  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/locale.json');
  Future<void> load() async { try { final f = await _f(); if (await f.exists()) { mode = (jsonDecode(await f.readAsString()) as Map)['mode'] as String? ?? 'system'; notifyListeners(); } } catch (_) {} }
  Future<void> set(String m) async { mode = m; notifyListeners(); try { await (await _f()).writeAsString(jsonEncode({'mode': m})); } catch (_) {} }
}

const _ar = {
  'Activity': 'النشاط', 'Chat': 'الدردشة', 'Calls': 'المكالمات', 'Teams': 'الفرق', 'Calendar': 'التقويم', 'Amer': 'عامر',
  'Agent Ops': 'عمليات الوكلاء', 'Control': 'التحكم', 'Health': 'حالة الخدمة', 'Users': 'المستخدمون', 'Security': 'الأمان', 'More': 'المزيد',
  'Chats': 'الدردشات', 'New encrypted chat': 'دردشة مشفرة جديدة', 'Search everywhere': 'البحث في كل مكان', 'Catch me up': 'أطلعني على ما فاتني',
  'Workflows': 'سير العمل', 'My agents': 'وكلائي', 'Notifications': 'الإشعارات', 'Find a time': 'إيجاد موعد', 'Sign out': 'تسجيل الخروج',
  'Language': 'اللغة', 'System': 'لغة الجهاز', 'Out of office': 'خارج المكتب', 'My tasks': 'مهامي', 'My decisions': 'قراراتي',
  'Message': 'رسالة', 'Nothing new': 'لا جديد', "You're all caught up": 'لا يوجد ما فاتك', 'Amer co-pilot': 'المساعد عامر',
  'All': 'الكل', 'Unread': 'غير المقروءة', 'People': 'الأشخاص', 'Groups': 'المجموعات', 'Pinned': 'المثبتة', 'Archived': 'المؤرشفة', 'Drafts': 'المسودات',
  '@Mentions': 'الإشارات', 'Followed threads': 'المحادثات المتابَعة', 'Search messages, files and people': 'ابحث في الرسائل والملفات والأشخاص',
};

/// The text in the user's language when a translation exists, otherwise as written (English).
String t(BuildContext c, String en) => Localizations.localeOf(c).languageCode == 'ar' ? (_ar[en] ?? en) : en;
