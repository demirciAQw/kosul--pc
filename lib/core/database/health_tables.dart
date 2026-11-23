/// Sağlık verisi tabloları (şema 22). Saf Dart.
///
/// HASSAS veri: bu tablolar değişiklik defterine, kablosuz eşitlemeye ve
/// bilgisayara birleştirmeye girmez (her cihaz kendi sağlık verisini kendisi
/// alır). Yedek ZIP'i tüm veritabanı olduğu için sağlık verisi yedeğe girer.
library;

const healthTables = {'saglik_gunluk', 'saglik_stres', 'saglik_uyku_oturum'};

/// Veri kaynağı adları (`kaynak` sütunu).
const healthSourceConnect = 'health_connect';
const healthSourceHuaweiZip = 'huawei_zip';
const healthSourceManual = 'manuel';
