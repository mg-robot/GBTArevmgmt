import { LightningElement, api } from 'lwc';

import LBL_PreviewTemplate from '@salesforce/label/c.PromoCodeWizard_S4_PreviewTemplate';
import LBL_StepDefinition from '@salesforce/label/c.PromoCodeWizard_Step_Definition';
import LBL_StepScopeEligibility from '@salesforce/label/c.PromoCodeWizard_Step_ScopeEligibility';
import LBL_StepLimitsBehavior from '@salesforce/label/c.PromoCodeWizard_Step_LimitsBehavior';
import LBL_Edit from '@salesforce/label/c.PromoCodeWizard_S4_Edit';
import LBL_S1_Code_Label from '@salesforce/label/c.PromoCodeWizard_S1_Code_Label';
import LBL_DisplayName from '@salesforce/label/c.PromoCodeWizard_S4_DisplayName_Label';
import LBL_DiscType from '@salesforce/label/c.PromoCodeWizard_S4_DiscType_Label';
import LBL_DiscValue from '@salesforce/label/c.PromoCodeWizard_S4_DiscValue_Label';
import LBL_Effective from '@salesforce/label/c.PromoCodeWizard_S4_Effective_Label';
import LBL_MemberTypes from '@salesforce/label/c.PromoCodeWizard_S4_MemberTypes_Label';
import LBL_Regions from '@salesforce/label/c.PromoCodeWizard_S4_Regions_Label';
import LBL_Products from '@salesforce/label/c.PromoCodeWizard_S4_Products_Label';
import LBL_Account from '@salesforce/label/c.PromoCodeWizard_S4_Account_Label';
import LBL_TotalLimit from '@salesforce/label/c.PromoCodeWizard_S4_TotalLimit_Label';
import LBL_PerMemberLimit from '@salesforce/label/c.PromoCodeWizard_S4_PerMemberLimit_Label';
import LBL_Combinable from '@salesforce/label/c.PromoCodeWizard_S4_Combinable_Label';
import LBL_ApprovalRequired from '@salesforce/label/c.PromoCodeWizard_S4_ApprovalRequired_Label';
import LBL_All from '@salesforce/label/c.PromoCodeWizard_S4_All';
import LBL_AllItems from '@salesforce/label/c.PromoCodeWizard_S4_AllItems';
import LBL_Unlimited from '@salesforce/label/c.PromoCodeWizard_S4_Unlimited';
import LBL_Any from '@salesforce/label/c.PromoCodeWizard_S4_Any';
import LBL_NoStart from '@salesforce/label/c.PromoCodeWizard_S4_NoStart';
import LBL_NoEnd from '@salesforce/label/c.PromoCodeWizard_S4_NoEnd';
import LBL_None from '@salesforce/label/c.PromoCodeWizard_S4_None';
import LBL_Yes from '@salesforce/label/c.PromoCodeWizard_S4_Yes';
import LBL_No from '@salesforce/label/c.PromoCodeWizard_S4_No';
import LBL_CombinableYesGroup from '@salesforce/label/c.PromoCodeWizard_S4_CombinableYesGroup';
import LBL_ProductFamilyPrefix from '@salesforce/label/c.PromoCodeWizard_S4_ProductFamilyPrefix';
import LBL_SpecificPrefix from '@salesforce/label/c.PromoCodeWizard_S4_SpecificPrefix';
import LBL_ActivationBanner from '@salesforce/label/c.PromoCodeWizard_S4_ActivationBanner';

/**
 * Step 4 of the wizard. Renders a read-only summary of every input from Steps 1-3
 * plus a per-currency preview of records that will be created. Emits `jumpto` when
 * the user clicks an Edit link on a section.
 */
export default class PromoCodeWizardStepReview extends LightningElement {
    @api wizardData;

    label = {
        sectionDefinition: LBL_StepDefinition,
        sectionScope: LBL_StepScopeEligibility,
        sectionLimits: LBL_StepLimitsBehavior,
        edit: LBL_Edit,
        code: LBL_S1_Code_Label,
        displayName: LBL_DisplayName,
        discType: LBL_DiscType,
        discValue: LBL_DiscValue,
        effective: LBL_Effective,
        applicationLevel: 'Application Level',
        regions: LBL_Regions,
        products: LBL_Products,
        account: LBL_Account,
        totalLimit: LBL_TotalLimit,
        perMemberLimit: LBL_PerMemberLimit,
        combinable: LBL_Combinable,
        approvalRequired: LBL_ApprovalRequired,
        activationBanner: LBL_ActivationBanner
    };

    get isPercent() { return this.wizardData?.discountType === 'Percent'; }
    get isAmount() { return this.wizardData?.discountType === 'Amount'; }

    get recordCount() {
        if (!this.wizardData) return 0;
        if (this.isPercent) return (this.wizardData.percentCurrencies || []).length;
        if (this.isAmount) return (this.wizardData.amounts || []).length;
        return 0;
    }

    get previewText() {
        return LBL_PreviewTemplate
            .replace('{0}', this.recordCount)
            .replace('{1}', this.wizardData?.code || '');
    }

    get recordPreview() {
        if (!this.wizardData) return [];
        if (this.isPercent) {
            return (this.wizardData.percentCurrencies || []).map((c) => ({
                label: `${this.wizardData.code} — ${c} — ${this.wizardData.percentValue}% off`
            }));
        }
        if (this.isAmount) {
            return (this.wizardData.amounts || []).map((a) => ({
                label: `${this.wizardData.code} — ${a.currencyIsoCode} — ${a.amount} off`
            }));
        }
        return [];
    }

    get discountValueDisplay() {
        const d = this.wizardData;
        if (!d) return '';
        if (this.isPercent) return `${d.percentValue}% (${(d.percentCurrencies || []).join(', ')})`;
        if (this.isAmount) {
            return (d.amounts || [])
                .map((a) => `${a.amount} ${a.currencyIsoCode}`)
                .join(', ');
        }
        return '';
    }

    get effectiveDisplay() {
        const s = this.wizardData?.effectiveStart || LBL_NoStart;
        const e = this.wizardData?.effectiveEnd || LBL_NoEnd;
        return `${s} → ${e}`;
    }
    get regionDisplay() {
        const arr = this.wizardData?.regionScope || [];
        return arr.length ? arr.join(', ') : LBL_All;
    }
    get applicationLevelDisplay() {
        return this.wizardData?.applicationLevel || '—';
    }
    get productScopeDisplay() {
        const d = this.wizardData || {};
        const t = d.productScopeType;
        if (t === 'All Items') return LBL_AllItems;
        if (t === 'Product Family') {
            const families = d.productFamilyScope || [];
            return `${LBL_ProductFamilyPrefix} ${families.length ? families.join(', ') : LBL_None}`;
        }
        if (t === 'Specific Membership Types') {
            const types = d.memberTypeScope || [];
            return `Specific Membership Types: ${types.length ? types.join(', ') : LBL_None}`;
        }
        if (t === 'Specific Products') {
            return `${LBL_SpecificPrefix} ${d.specificProducts || LBL_None}`;
        }
        return '—';
    }
    get accountDisplay() { return this.wizardData?.accountId || LBL_Any; }
    get totalLimitDisplay() {
        return this.wizardData?.totalLimit == null ? LBL_Unlimited : String(this.wizardData.totalLimit);
    }
    get perMemberLimitDisplay() {
        return this.wizardData?.perMemberLimit == null ? LBL_Unlimited : String(this.wizardData.perMemberLimit);
    }
    get combinableDisplay() {
        if (!this.wizardData?.combinable) return LBL_No;
        return LBL_CombinableYesGroup.replace('{0}', this.wizardData.combinationGroup || '—');
    }
    get approvalDisplay() { return this.wizardData?.approvalRequired ? LBL_Yes : LBL_No; }

    handleEditClick(event) {
        event.preventDefault();
        const step = event.currentTarget.dataset.step;
        this.dispatchEvent(new CustomEvent('jumpto', { detail: { step } }));
    }
}
