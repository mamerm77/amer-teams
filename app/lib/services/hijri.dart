/// Hijri dates (docs/ARABIC.md): the arithmetical (tabular, Kuwaiti) Islamic calendar, the same as the server's
/// find-a-time uses. It can differ by a day from the local moon sighting.
class Hijri {
  const Hijri(this.year, this.month, this.day);
  final int year, month, day;
  static const monthsAr = ['محرم', 'صفر', 'ربيع الأول', 'ربيع الآخر', 'جمادى الأولى', 'جمادى الآخرة', 'رجب', 'شعبان', 'رمضان', 'شوال', 'ذو القعدة', 'ذو الحجة'];
  static const monthsEn = ['Muharram', 'Safar', 'Rabi al-Awwal', 'Rabi al-Thani', 'Jumada al-Ula', 'Jumada al-Akhirah', 'Rajab', "Sha'ban", 'Ramadan', 'Shawwal', "Dhu al-Qa'dah", 'Dhu al-Hijjah'];
  static Hijri of(DateTime d) {
    var y = d.year, m = d.month; if (m <= 2) { y -= 1; m += 12; }
    final a = y ~/ 100, b = 2 - a + a ~/ 4;
    final jd = ((365.25 * (y + 4716)).floor() + (30.6001 * (m + 1)).floor() + d.day + b - 1524.5 + 0.5).floor();
    var l = jd - 1948440 + 10632; final n = (l - 1) ~/ 10631; l = l - 10631 * n + 354;
    final j = ((10985 - l) ~/ 5316) * ((50 * l) ~/ 17719) + (l ~/ 5670) * ((43 * l) ~/ 15238);
    l = l - ((30 - j) ~/ 15) * ((17719 * j) ~/ 50) - (j ~/ 16) * ((15238 * j) ~/ 43) + 29;
    final mo = (24 * l) ~/ 709, day = l - (709 * mo) ~/ 24, yr = 30 * n + j - 30;
    return Hijri(yr, mo, day);
  }
  String format({bool arabic = false}) => arabic ? '$day ${monthsAr[month - 1]} $year هـ' : '$day ${monthsEn[month - 1]} $year AH';
}
