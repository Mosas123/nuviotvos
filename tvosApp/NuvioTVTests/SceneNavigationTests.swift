import XCTest
import SwiftUI
@testable import NuvioTV

@MainActor
final class SceneNavigationTests: XCTestCase {
    
    func testRemoteDownOpensSceneWithoutPauseOrSeek() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        XCTAssertFalse(viewModel.showScenePanel)
        
        // Simulating remote Down when controls are hidden
        viewModel.openScene()
        
        XCTAssertTrue(viewModel.showScenePanel)
        XCTAssertEqual(viewModel.status, .playing, "Playback must not pause when Scene opens")
        XCTAssertEqual(viewModel.sceneViewModel.selectedTab, .scene, "Scene tab must be selected initially")
    }
    
    func testTabsAndCardsFocusNavigationLifecycle() {
        let coordinator = SceneCoordinator(
            frameProvider: UnsupportedSceneFrameProvider()
        )
        let sceneVM = SceneViewModel(coordinator: coordinator)
        
        sceneVM.open()
        XCTAssertTrue(sceneVM.isVisible)
        XCTAssertEqual(sceneVM.selectedTab, .scene)
        
        // Switching tabs
        sceneVM.selectTab(.info)
        XCTAssertEqual(sceneVM.selectedTab, .info)
        
        sceneVM.selectTab(.scene)
        XCTAssertEqual(sceneVM.selectedTab, .scene)
        
        // Opening detail sheet
        let actor = SceneRecognizedActor(id: "1", name: "Keanu Reeves", character: "Neo")
        sceneVM.openDetail(.actor(actor, detail: ScenePersonDetail(id: 1, name: "Keanu Reeves", biography: "Action star")))
        XCTAssertTrue(sceneVM.isDetailVisible)
        
        // Back/Menu closes detail first
        sceneVM.closeDetail()
        XCTAssertFalse(sceneVM.isDetailVisible)
        XCTAssertTrue(sceneVM.isVisible, "Closing detail sheet should keep Scene panel open")
        
        // Up/Back closes Scene panel
        sceneVM.close()
        XCTAssertFalse(sceneVM.isVisible)
    }
    
    func testControlsAutoHideSuspendedWhileSceneOpen() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        
        viewModel.openScene()
        XCTAssertTrue(viewModel.showScenePanel)
        
        // When Scene is open, closing it restores normal auto-hide behavior
        viewModel.closeScene()
        XCTAssertFalse(viewModel.showScenePanel)
    }
    
    func testPlayPauseTogglesPlaybackWithoutDismissingScene() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.openScene()
        XCTAssertTrue(viewModel.showScenePanel)
        
        // Toggle play/pause
        viewModel.pause()
        XCTAssertEqual(viewModel.status, .paused)
        XCTAssertTrue(viewModel.showScenePanel, "Scene must remain open when pausing")
        
        viewModel.play()
        XCTAssertEqual(viewModel.status, .playing)
        XCTAssertTrue(viewModel.showScenePanel, "Scene must remain open when resuming")
        
        viewModel.closeScene()
    }
    
    func testScrubbingAndErrorPrecedenceOverScene() {
        let viewModel = PlayerViewModel()
        viewModel.status = .paused
        
        // When scrubbing, remote input is owned by scrub
        viewModel.beginScrub()
        // An active scrub retains input ownership; Down must not open Scene
        XCTAssertTrue(viewModel.isScrubbing)
        
        viewModel.cancelScrub()
        XCTAssertFalse(viewModel.isScrubbing)
    }
    
    func testSceneInfoTabPlaybackTelemetryPopulated() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        
        viewModel.openScene()
        XCTAssertTrue(viewModel.showScenePanel)
        
        // Assert playbackInfo is populated
        let playbackInfo = viewModel.sceneViewModel.playbackInfo
        XCTAssertNotNil(playbackInfo, "Playback info must be populated when opening Scene")
        XCTAssertEqual(playbackInfo?.engine, "AetherEngine")
        XCTAssertEqual(playbackInfo?.version, "7.36.0")
        XCTAssertEqual(playbackInfo?.videoCodec, "—")
        XCTAssertEqual(playbackInfo?.resolution, "—")
        XCTAssertEqual(playbackInfo?.frameRate, "—")
        XCTAssertEqual(playbackInfo?.dynamicRange, "—")
        XCTAssertNil(playbackInfo?.dolbyVisionProfile)
        XCTAssertEqual(playbackInfo?.videoBitrate, "—")
        XCTAssertEqual(playbackInfo?.container, "—")
        XCTAssertEqual(playbackInfo?.videoDecoder, "—")
        XCTAssertEqual(playbackInfo?.audioCodec, "—")
        XCTAssertEqual(playbackInfo?.audioChannels, "—")
        XCTAssertEqual(playbackInfo?.audioLanguage, "—")
        XCTAssertEqual(playbackInfo?.audioBitrate, "—")
        XCTAssertEqual(playbackInfo?.audioDecoder, "—")
        
        // Test Dolby Vision fallback telemetry model
        let dvInfo = ScenePlaybackInfo(
            dynamicRange: "Dolby Vision → HDR10",
            dolbyVisionProfile: "5"
        )
        viewModel.sceneViewModel.updatePlaybackInfo(dvInfo)
        XCTAssertEqual(viewModel.sceneViewModel.playbackInfo?.dynamicRange, "Dolby Vision → HDR10")
        XCTAssertEqual(viewModel.sceneViewModel.playbackInfo?.dolbyVisionProfile, "5")
        
        // Switching to info tab maintains playback telemetry
        viewModel.sceneViewModel.selectTab(.info)
        XCTAssertEqual(viewModel.sceneViewModel.selectedTab, .info)
        XCTAssertNotNil(viewModel.sceneViewModel.playbackInfo)
    }

    func testFreshAetherMetricsStayUnavailableAndMPVHandoffUsesActiveSnapshot() throws {
        guard let aetherController = AetherPlaybackController() else {
            throw XCTSkip("AetherEngine is unavailable in this test environment")
        }
        let aetherSnapshot = aetherController.playbackDebugInfo
        XCTAssertTrue(aetherSnapshot.frameRate.isEmpty)
        XCTAssertTrue(aetherSnapshot.aBitrate.isEmpty)

        let mpvSnapshot = PlaybackDebugInfo(
            videoCodec: "AV1",
            resolution: "1920×1080",
            frameRate: "59.940 fps",
            vBitrate: "avg mux 8.0 Mbit/s",
            aBitrate: "meas 2.00 Mbit/s"
        )
        let activeSnapshot = PlayerViewModel.selectedScenePlaybackDebugInfo(
            activeEngineKind: .mpv,
            aether: aetherSnapshot,
            mpv: mpvSnapshot
        )

        XCTAssertEqual(activeSnapshot, mpvSnapshot)
        XCTAssertEqual(activeSnapshot?.videoCodec, "AV1")
        XCTAssertEqual(activeSnapshot?.frameRate, "59.940 fps")
        XCTAssertEqual(activeSnapshot?.aBitrate, "meas 2.00 Mbit/s")
    }
}
