/// The Clock screensaver's Night mode decision, shared by its appearance
/// and screen-power policy. Leave only 25% above the threshold so readings
/// near the boundary do not repeatedly change the display.
bool clockNightActive({
  required bool previous,
  required bool enabled,
  required double? lux,
  required double threshold,
}) {
  if (!enabled || lux == null || !lux.isFinite || lux < 0) return false;
  if (lux <= threshold) return true;
  if (lux > threshold * 1.25) return false;
  return previous;
}
