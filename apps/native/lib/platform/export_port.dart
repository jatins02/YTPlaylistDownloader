import '../domain/device_export.dart';
import 'media_port.dart';

abstract interface class ExportMediaPort implements MediaPort {
  Future<ExportPublication?> currentExport(String jobId);
  Future<ExportPublication> prepareExport(
    String jobId,
    int revision, {
    bool fillMissingMetadata = false,
  });
  Future<DeliveryReceipt?> deliverExport(
    ExportPublication publication,
    String fileId,
  );
  Future<void> stopExport(String jobId);
}
