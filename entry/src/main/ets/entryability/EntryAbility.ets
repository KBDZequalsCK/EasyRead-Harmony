import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppContext, FileService } from '../service/FileService';
import { TextSupport } from '../service/TextSupport';
import { LibraryStore } from '../service/LibraryStore';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const mainWindow = windowStage.getMainWindowSync();
    AppContext.init(this.context, mainWindow);
    FileService.ensureBaseDirs();
    TextSupport.install();
    windowStage.loadContent('pages/Index', (error: BusinessError): void => {
    });
  }

  onBackground(): void {
    LibraryStore.shared().flush();
  }

  onDestroy(): void {
    LibraryStore.shared().flush();
  }
}
