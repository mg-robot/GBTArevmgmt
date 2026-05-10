import { LightningElement } from 'lwc';

export default class PromoCodeLauncher extends LightningElement {
    showWizard = false;

    handleOpen() {
        this.showWizard = true;
    }

    handleClose() {
        this.showWizard = false;
    }
}
