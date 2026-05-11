import { LightningElement } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import PromoCodeWizard from 'c/promoCodeWizard';

import LBL_ModalTitle from '@salesforce/label/c.PromoCodeWizard_Modal_Title';

/**
 * Headless launcher used as the Lightning Web Component override for the standard
 * New action on Promo_Code__c. Opens PromoCodeWizard and dismisses the action
 * container on close.
 */
export default class PromoCodeWizardButton extends LightningElement {
    _opened = false;

    async connectedCallback() {
        if (this._opened) return;
        this._opened = true;
        try {
            await PromoCodeWizard.open({
                size: 'medium',
                label: LBL_ModalTitle
            });
        } catch (e) {
            // swallow
        } finally {
            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }
}
