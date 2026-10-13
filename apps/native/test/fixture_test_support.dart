import 'package:yt_playlist_downloader/application/fixture_journey.dart';

const demoLink = 'https://youtube.com/playlist?list=PLfictionalDemo01';

FixtureJourney reviewed([FixtureScenario scenario = FixtureScenario.partial]) {
  final journey = FixtureJourney()..chooseScenario(scenario);
  journey.start(demoLink);
  journey.advance();
  while (journey.phase == FixturePhase.processing) {
    journey.advance();
  }
  return journey;
}
