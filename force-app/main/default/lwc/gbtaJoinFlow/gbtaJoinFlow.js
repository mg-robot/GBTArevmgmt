import { LightningElement, api, track, wire } from 'lwc';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import CONTACT_OBJECT from '@salesforce/schema/Contact';
import ORGANIZATION_INDUSTRY_FIELD from '@salesforce/schema/Contact.Organization_industry__c';
import ANNUAL_SPEND_FIELD from '@salesforce/schema/Contact.Organization_recent_travel_spend_USD__c';
import ORGANIZATION_TYPE_FIELD from '@salesforce/schema/Contact.Organization_type__c';
import YEARS_IN_INDUSTRY_FIELD from '@salesforce/schema/Contact.Years_in_Business_Travel_Industry__c';
import PRIMARY_INTERESTS_FIELD from '@salesforce/schema/Contact.Primary_areas_of_interest__c';
import PROGRAM_INTERESTS_FIELD from '@salesforce/schema/Contact.Program_areas_interested_in__c';
import COMPANY_ROLE_FIELD from '@salesforce/schema/Contact.Role__c';
import PRIMARY_JOB_FUNCTION_FIELD from '@salesforce/schema/Contact.Primary_job_function__c';
import { NavigationMixin } from 'lightning/navigation';
import getCurrentUserPersonAccountInfo from '@salesforce/apex/PersonAccountController.getCurrentUserPersonAccountInfo';


import getActiveMembershipAsset from '@salesforce/apex/UserAssetsController.getActiveMembershipAsset';
import renewAssets from '@salesforce/apex/UserAssetsController.renewAssets';

import savePersonAccountInfo            from '@salesforce/apex/PersonAccountController.savePersonAccountInfo';
import saveQualificationInfo            from '@salesforce/apex/PersonAccountController.saveQualificationInfo';
import getMembershipPriceFromMatrix     from '@salesforce/apex/PersonAccountController.getMembershipPriceFromMatrix';
import getMembershipProducts            from '@salesforce/apex/PersonAccountController.getMembershipProducts';
import getChapterProducts             from '@salesforce/apex/PersonAccountController.getChapterProducts';
import placeMembershipOrder           from '@salesforce/apex/PersonAccountController.placeMembershipOrder';
import searchBusinessAccounts from '@salesforce/apex/PersonAccountController.searchBusinessAccounts';
import createBusinessAccount  from '@salesforce/apex/PersonAccountController.createBusinessAccount';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// ── Constants ──────────────────────────────────────────────────

const STEP_LABELS = ['Your Info', 'Qualify', 'Result', 'Chapters', 'Select', 'Review'];

const CHAPTERS_PER_PAGE = 9;

// ── Job function picklist API values ───────────────────────────
const JF_CORPORATE_BUYER = 'I procure or manage travel, payments, expense, policy or meetings-related services/products for travelers of my own organization';
const JF_OUTSOURCED_MGR  = "I am an outsourced travel manager, or source/service travel, meetings programs or policies for one dedicated corporate client and use their company's email address as my work email";
const JF_CONSULTANT      = 'I am a consultant for corporate travel and meeting programs';
const JF_SUPPLIER        = 'I am a supplier or technology provider for business travel-related products/services';
const JF_STUDENT         = 'I am a full-time Student';
const JF_ACADEMIC        = 'I am a full-time professor or educator';
const JF_PRESS           = 'I am a member of the press';

// ── Helpers ────────────────────────────────────────────────────

function makeOption(value, label, selected) {
    return {
        value,
        label,
        checked: selected,
        optionClass: `jf-option-label${selected ? ' jf-option-label--selected' : ''}`
    };
}

function fmt(amount) {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount);
}

// ── Component ──────────────────────────────────────────────────

export default class GbtaJoinFlow extends NavigationMixin(LightningElement) {

    // ── @api design attributes ─────────────────────────────────
    @api buttonLabel = 'Join Now';
    @api buttonVariant = 'primary';
    @api checkoutPageApiName;

    // ── Modal state ────────────────────────────────────────────
    @track isOpen = false;
    @track currentStep = 0;
    @track activeMembershipAsset = null;
    @track activeMembershipType = '';
    @track isRenewing = false;
    @track renewError = '';

    // ── Step 0: Your Information ───────────────────────────────
    @track accountId = null;
    @track firstName = '';
    @track lastName = '';
    @track email = '';
    @track title = '';
    @track phone = '';
    @track billingCountry = 'US';
    @track billingStreet = '';
    @track billingCity = '';
    @track billingState = '';
    @track billingZip = '';

    // ── Step 0: Shipping address ───────────────────────────────
    @track shippingSameAsBilling = true;
    @track shippingCountry = 'US';
    @track shippingStreet = '';
    @track shippingCity = '';
    @track shippingState = '';
    @track shippingZip = '';

    // ── Step 0: Company search-ahead ──────────────────────────
    @track companyMode            = 'search'; // 'search' | 'create'
    @track companySearchTerm      = '';
    @track companySearchResults   = [];
    @track companyDropdownVisible = false;
    @track selectedCompanyId      = null;
    @track selectedCompanyName    = '';
    @track newCompanyName         = '';
    @track companySearchError     = '';
    @track isCreatingCompany      = false;
    // Address fields (inside create form — bound to lightning-input-address)
    @track newCompanyStreet   = '';
    @track newCompanyCity     = '';
    @track newCompanyState    = '';
    @track newCompanyZip      = '';
    @track newCompanyCountry  = 'US';

    _companySearchTimer = null;

    // ── Step 0: validation & save state ───────────────────────
    @track step0Errors = {};
    @track isSaving = false;
    @track step0SaveError = '';

    // ── Step 1: save state ─────────────────────────────────────
    @track isSavingStep1 = false;
    @track step1SaveError = '';
    @track step1Errors = {};

    // ── Step 1: Qualification ─────────────────────────────────
    @track jobFunction = '';
    @track orgType = '';
    @track yearsInIndustry = '';
    @track primaryInterests = [];
    @track programInterests = [];
    @track companyRole = '';
    @track industrySector = '';
    @track industrySectorOther = '';
    @track annualTravelSpend = '';
    @track institution = '';
    @track graduationDate = '';
    @track academicInstitution = '';

    // ── Membership products (loaded on open) ──────────────────
    @track membershipProducts = [];

    // ── Chapter products & region (loaded on open) ────────────
    @track chapterProducts = [];
    @track region = '';

    // ── Step 4: Chapter Selection ──────────────────────────────
    @track selectedChapters = [];
    @track primaryChapterId = null;
    @track chapterPage = 0;
    @track chapterOptOut = false;
    @track chapterSearchTerm = '';

    // ── Step 2: Matrix price ───────────────────────────────────
    @track matrixPrice = null;
    @track globalPartnerLookup = '';

    // ── Step 5: Checkout state ─────────────────────────────────
    @track isPlacingOrder = false;
    @track orderError = '';

    // ── Picklist wire adapters ─────────────────────────────────
    @wire(getObjectInfo, { objectApiName: CONTACT_OBJECT })
    _contactInfo;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: ORGANIZATION_INDUSTRY_FIELD })
    wiredIndustryPicklist(result) {
        console.log('Industry picklist result:', JSON.stringify(result));
        this._industryPicklist = result;
    }

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: ANNUAL_SPEND_FIELD })
    _annualSpendPicklist;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: ORGANIZATION_TYPE_FIELD })
    _orgTypePicklist;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: YEARS_IN_INDUSTRY_FIELD })
    _yearsPicklist;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: PRIMARY_INTERESTS_FIELD })
    _primaryInterestsPicklist;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: PROGRAM_INTERESTS_FIELD })
    _programInterestsPicklist;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: COMPANY_ROLE_FIELD })
    _companyRolePicklist;

    @wire(getPicklistValues, { recordTypeId: '$_contactInfo.data.defaultRecordTypeId', fieldApiName: PRIMARY_JOB_FUNCTION_FIELD })
    _jobFunctionPicklist;

    // ── Step Indicator ─────────────────────────────────────────
    // stepBarItems interleaves circle nodes and line connectors so the
    // template never needs :last-child (which doesn't pierce LWC shadow DOM).

    // Maps internal step indices to labels; chapter steps (3, 4) are excluded
    // entirely when the region is not USA so they don't appear in the indicator.
    get visibleStepDefs() {
        const all = [
            { idx: 0, label: 'Your Info' },
            { idx: 1, label: 'Qualify' },
            { idx: 2, label: 'Result' },
            { idx: 3, label: 'Chapters' },
            { idx: 4, label: 'Select' },
            { idx: 5, label: 'Review' },
        ];
        return this.region === 'USA' ? all : all.filter(s => s.idx !== 3 && s.idx !== 4);
    }

    get stepBarItems() {
        const items = [];
        const steps = this.visibleStepDefs;
        steps.forEach((step, pos) => {
            const i = step.idx;
            items.push({
                key: `node-${i}`,
                isCircle: true,
                number: pos + 1,
                isCompleted: i < this.currentStep,
                wrapClass: 'jf-sn-node',
                circleClass: `jf-sn-circle ${
                    i < this.currentStep
                        ? 'jf-sn-circle--done'
                        : i === this.currentStep
                            ? 'jf-sn-circle--active'
                            : 'jf-sn-circle--future'
                }`
            });
            if (pos < steps.length - 1) {
                items.push({
                    key: `line-${i}`,
                    isCircle: false,
                    wrapClass: `jf-sn-line-wrap${i < this.currentStep ? ' jf-sn-line-wrap--filled' : ''}`
                });
            }
        });
        return items;
    }

    // stepNodes drives the labels row — interleaves label cells and flex spacers
    // to mirror the bar structure (30px circles + flex-1 lines).
    get stepNodes() {
        const items = [];
        const steps = this.visibleStepDefs;
        steps.forEach((step, pos) => {
            const i = step.idx;
            const colorClass = i < this.currentStep
                ? 'jf-sn-label--done'
                : i === this.currentStep
                    ? 'jf-sn-label--active'
                    : 'jf-sn-label';
            items.push({ key: `label-${i}`, label: step.label, cellClass: `jf-sn-label-cell ${colorClass}` });
            if (pos < steps.length - 1) {
                items.push({ key: `spacer-${i}`, label: '', cellClass: 'jf-sn-label-spacer' });
            }
        });
        return items;
    }

    // ── Step visibility getters ────────────────────────────────

    get isStep0() { return this.currentStep === 0; }
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get isStep5() { return this.currentStep === 5; }
    get isLastStep() { return this.currentStep === 5; }
    get showChapters() { return this.region === 'USA'; }

    // ── Membership gate getters ────────────────────────────────
    get showMembershipGate() { return this.activeMembershipAsset !== null; }
    get noActiveMembership() { return !this.showMembershipGate; }
    get isGlobalPartnerMember() { return this.activeMembershipType === 'Global Partner'; }
    get isEnterpriseMember() { return this.activeMembershipType === 'Enterprise'; }
    get isRenewableMember() { return this.activeMembershipType === 'Individual'; }
    get renewButtonLabel() { return this.isRenewing ? 'Renewing…' : 'Renew Membership'; }

    // ── Navigation button state ────────────────────────────────

    get isPrevDisabled() { return this.currentStep === 0; }

    get prevBtnClass() {
        return `jf-btn jf-btn--secondary${this.currentStep === 0 ? ' jf-btn--dimmed' : ''}`;
    }

    get showOptOut() { return this.currentStep === 3; }

    get nextButtonLabel() {
        if (this.currentStep === 0 && this.isSaving) return 'Saving…';
        return this.currentStep === 3 ? 'Next Page →' : 'Next →';
    }

    get isNextDisabled() {
        return this.currentStep === 0 && this.isSaving;
    }

    // ── Launcher button ────────────────────────────────────────

    get launcherBtnClass() {
        const v = this.buttonVariant;
        if (v === 'secondary') return 'jf-launch-btn jf-launch-btn--secondary';
        if (v === 'ghost') return 'jf-launch-btn jf-launch-btn--ghost';
        return 'jf-launch-btn jf-launch-btn--primary';
    }

    // ── Step 0 helpers ─────────────────────────────────────────

    get showShippingFields() { return !this.shippingSameAsBilling; }

    get step0FieldClasses() {
        const e = this.step0Errors;
        const inp = (f) => `jf-input${e[f] ? ' jf-input--error' : ''}`;
        return {
            firstName: inp('firstName'),
            lastName:  inp('lastName'),
            email:     inp('email'),
            title:     inp('title'),
            phone:     inp('phone')
        };
    }

    get isSearchMode()          { return this.companyMode === 'search'; }
    get isCreateMode()          { return this.companyMode === 'create'; }
    get modeToggleBtnLabel()    { return this.companyMode === 'search' ? 'Create a Company' : 'Search a Company'; }
    get showSelectedSection()   { return !!this.selectedCompanyId && this.companyMode === 'search'; }
    get createCompanyBtnLabel() { return this.isCreatingCompany ? 'Creating…' : 'Create Company'; }



    // ── Step 1 conditional display ────────────────────────────

    get showOrgType()         { return this.jobFunctionLabel === JF_CORPORATE_BUYER; }
    get showYearsInIndustry() {
        const jf = this.jobFunctionLabel;
        return jf !== '' && jf !== JF_STUDENT && jf !== JF_ACADEMIC && jf !== JF_PRESS;
    }
    get showCompanySection() {
        return [JF_CORPORATE_BUYER, JF_OUTSOURCED_MGR, JF_CONSULTANT, JF_SUPPLIER].includes(this.jobFunctionLabel);
    }
    get showCompanyRole()     { return [JF_CORPORATE_BUYER, JF_OUTSOURCED_MGR, JF_CONSULTANT, JF_SUPPLIER].includes(this.jobFunctionLabel); }
    get showAnnualSpend()     { return [JF_CORPORATE_BUYER, JF_OUTSOURCED_MGR].includes(this.jobFunctionLabel); }
    get isCorporateJob()      { return [JF_CORPORATE_BUYER, JF_OUTSOURCED_MGR].includes(this.jobFunctionLabel); }
    get isStudentRole()       { return this.jobFunctionLabel === JF_STUDENT; }
    get isAcademicRole()      { return this.jobFunctionLabel === JF_ACADEMIC; }
    get showOtherSectorInput() {
        if (!this.industrySector) return false;
        const values = this._industryPicklist?.data?.values;
        if (!values) return false;
        const selected = values.find(o => o.value === this.industrySector);
        return selected ? selected.label.toLowerCase().startsWith('other') : false;
    }

    // ── Step 1 option getters ─────────────────────────────────

    // Resolves the display label for the stored API value so conditional
    // getters can compare against the human-readable constants (JF_*).
    get jobFunctionLabel() {
        const match = (this._jobFunctionPicklist?.data?.values || [])
            .find(v => v.value === this.jobFunction);
        return match?.label ?? this.jobFunction;
    }

    get jobFunctionOptions() {
        const wired = this._jobFunctionPicklist?.data?.values;
        const v = this.jobFunction;
        const row = (val) => `jf-q-row${v === val ? ' jf-q-row--selected' : ''}`;
        if (wired?.length) {
            return wired.map(item => ({
                value:    item.value,
                label:    item.label,
                checked:  v === item.value,
                rowClass: row(item.value)
            }));
        }
        // Fallback while wire is pending — keeps the UI responsive on first open
        return [
            { value: JF_CORPORATE_BUYER, label: JF_CORPORATE_BUYER, checked: v === JF_CORPORATE_BUYER, rowClass: row(JF_CORPORATE_BUYER) },
            { value: JF_OUTSOURCED_MGR,  label: JF_OUTSOURCED_MGR,  checked: v === JF_OUTSOURCED_MGR,  rowClass: row(JF_OUTSOURCED_MGR)  },
            { value: JF_CONSULTANT,      label: JF_CONSULTANT,      checked: v === JF_CONSULTANT,      rowClass: row(JF_CONSULTANT)      },
            { value: JF_SUPPLIER,        label: JF_SUPPLIER,        checked: v === JF_SUPPLIER,        rowClass: row(JF_SUPPLIER)        },
            { value: JF_STUDENT,         label: JF_STUDENT,         checked: v === JF_STUDENT,         rowClass: row(JF_STUDENT)         },
            { value: JF_ACADEMIC,        label: JF_ACADEMIC,        checked: v === JF_ACADEMIC,        rowClass: row(JF_ACADEMIC)        },
            { value: JF_PRESS,           label: JF_PRESS,           checked: v === JF_PRESS,           rowClass: row(JF_PRESS)           }
        ];
    }

    get orgTypeOptions() {
        const values = this._orgTypePicklist?.data?.values;
        if (!values) return [];
        const v = this.orgType;
        const row = (val) => `jf-q-row${v === val ? ' jf-q-row--selected' : ''}`;
        return values.map(o => ({
            value:    o.value,
            label:    o.label,
            checked:  v === o.value,
            rowClass: row(o.value)
        }));
    }

    get yearsOptions() {
        const values = this._yearsPicklist?.data?.values;
        if (!values) return [];
        const v = this.yearsInIndustry;
        const pill = (val) => `jf-pill${v === val ? ' jf-pill--selected' : ''}`;
        return values.map(o => ({
            value:     o.value,
            label:     o.label,
            checked:   v === o.value,
            pillClass: pill(o.value)
        }));
    }

    get primaryInterestOptions() {
        const values = this._primaryInterestsPicklist?.data?.values;
        if (!values) return [];
        const sel = this.primaryInterests;
        const row = (val) => `jf-q-row${sel.includes(val) ? ' jf-q-row--selected' : ''}`;
        return values.map(o => ({
            value:    o.value,
            label:    o.label,
            checked:  sel.includes(o.value),
            rowClass: row(o.value)
        }));
    }
    get allPrimarySelected()   { return this.primaryInterests.length > 0 && this.primaryInterests.length === (this._primaryInterestsPicklist?.data?.values?.length ?? -1); }
    get primarySelectAllClass(){ return `jf-q-row${this.allPrimarySelected ? ' jf-q-row--selected' : ''}`; }

    get programInterestOptions() {
        const values = this._programInterestsPicklist?.data?.values;
        if (!values) return [];
        const sel = this.programInterests;
        const row = (val) => `jf-q-row${sel.includes(val) ? ' jf-q-row--selected' : ''}`;
        return values.map(o => ({
            value:    o.value,
            label:    o.label,
            checked:  sel.includes(o.value),
            rowClass: row(o.value)
        }));
    }
    get allProgramsSelected()   { return this.programInterests.length > 0 && this.programInterests.length === (this._programInterestsPicklist?.data?.values?.length ?? -1); }
    get programSelectAllClass() { return `jf-q-row${this.allProgramsSelected ? ' jf-q-row--selected' : ''}`; }

    get companyRoleOptions() {
        const values = this._companyRolePicklist?.data?.values;
        if (!values) return [];
        const v = this.companyRole;
        const row = (val) => `jf-q-row${v === val ? ' jf-q-row--selected' : ''}`;
        return values.map(o => ({
            value:    o.value,
            label:    o.label,
            checked:  v === o.value,
            rowClass: row(o.value)
        }));
    }

    get industrySectorOptions() {
        const values = this._industryPicklist?.data?.values;
        if (!values) return [];
        const v = this.industrySector;
        const row = (val) => `jf-q-row${v === val ? ' jf-q-row--selected' : ''}`;
        return values.map(o => ({
            value:    o.value,
            label:    o.label,
            checked:  v === o.value,
            rowClass: row(o.value)
        }));
    }

    get annualSpendOptions() {
        const values = this._annualSpendPicklist?.data?.values;
        if (!values) return [];
        const v = this.annualTravelSpend;
        const row = (val) => `jf-q-row${v === val ? ' jf-q-row--selected' : ''}`;
        return values.map(o => ({
            value:    o.value,
            label:    o.label,
            checked:  v === o.value,
            rowClass: row(o.value)
        }));
    }

    // ── Step 2: Membership calculation ────────────────────────

    get membershipType() {
        const jf = this.jobFunctionLabel;
        if (jf === JF_PRESS)    return 'Press Membership';
        if (jf === JF_STUDENT)  return 'Student Membership';
        if (jf === JF_ACADEMIC) return 'Educator Membership';
        if (jf === JF_SUPPLIER || jf === JF_CONSULTANT) return 'Allied Membership';
        if (jf === JF_OUTSOURCED_MGR) return 'Direct Membership';
        if (jf === JF_CORPORATE_BUYER) {
            if (this.orgType === 'government') return 'Government Membership';
            if (this.orgType === 'nonprofit')  return 'Nonprofit Membership';
            return 'Direct Membership';
        }
        return 'Direct Membership';
    }

    get membershipPriceMap() {
        const map = {};
        this.membershipProducts.forEach(p => { map[p.name] = p.price; });
        return map;
    }

    get membershipPbeId() {
        const match = this.membershipProducts.find(p => p.name === this.membershipType);
        return match ? match.pbeId : null;
    }

    get membershipProduct2Id() {
        const match = this.membershipProducts.find(p => p.name === this.membershipType);
        return match ? match.product2Id : null;
    }

    get checkoutButtonLabel() {
        return this.isPlacingOrder ? 'Placing Order…' : 'Proceed to Checkout →';
    }

    get isCheckoutDisabled() {
        return this.isPlacingOrder;
    }

    get membershipPrice() {
        if (this.globalPartnerLookup) return 0;
        if (this.matrixPrice !== null) return this.matrixPrice;
        return this.membershipPriceMap[this.membershipType] ?? 0;
    }

    get formattedMembershipPrice() {
        return fmt(this.membershipPrice);
    }

    // ── Step 4: Chapter list with pagination ──────────────────

    get filteredChapters() {
        const term = (this.chapterSearchTerm || '').toLowerCase().trim();
        if (!term) return this.chapterProducts;
        return this.chapterProducts.filter(ch =>
            (ch.name     || '').toLowerCase().includes(term) ||
            (ch.location || '').toLowerCase().includes(term)
        );
    }

    get visibleChapters() {
        const start = this.chapterPage * CHAPTERS_PER_PAGE;
        return this.filteredChapters.slice(start, start + CHAPTERS_PER_PAGE).map((ch) => {
            const isSelected = this.selectedChapters.includes(ch.id);
            const isPrimary  = this.primaryChapterId === ch.id;
            return {
                ...ch,
                isSelected,
                isPrimary,
                cardClass:        `jf-chapter-card${isSelected ? ' jf-chapter-card--selected' : ''}`,
                primaryWrapClass: `jf-chapter-primary-wrap${isPrimary ? ' jf-chapter-primary-wrap--active' : ''}`
            };
        });
    }

    get totalChapterPages() {
        return Math.ceil(this.filteredChapters.length / CHAPTERS_PER_PAGE);
    }

    get paginationText() {
        const total = this.filteredChapters.length;
        if (total === 0) return 'No chapters found';
        const start = this.chapterPage * CHAPTERS_PER_PAGE + 1;
        const end   = Math.min((this.chapterPage + 1) * CHAPTERS_PER_PAGE, total);
        return `Viewing ${start}–${end} of ${total}`;
    }

    get chapterPageButtons() {
        return Array.from({ length: this.totalChapterPages }, (_, i) => ({
            key:       i,
            label:     String(i + 1),
            btnClass:  `jf-page-btn${this.chapterPage === i ? ' jf-page-btn--active' : ''}`
        }));
    }

    get noChapterResults() {
        return this.chapterSearchTerm.trim() !== '' && this.filteredChapters.length === 0;
    }

    // ── Step 5: Cart ───────────────────────────────────────────

    get hasChapters() { return this.selectedChapters.length > 0; }

    get cartItems() {
        const items = [
            {
                id: 'membership',
                label: this.membershipType,
                formattedPrice: fmt(this.membershipPrice)
            }
        ];
        const selected = this.chapterProducts.filter(ch => this.selectedChapters.includes(ch.id));
        selected.forEach(ch => {
            items.push({
                id: `ch-${ch.id}`,
                label: `Chapter Selection: ${ch.name}`,
                formattedPrice: fmt(ch.price || 0)
            });
        });
        return items;
    }

    get totalDue() {
        const chapterTotal = this.chapterProducts
            .filter(ch => this.selectedChapters.includes(ch.id))
            .reduce((sum, ch) => sum + (ch.price || 0), 0);
        return this.membershipPrice + chapterTotal;
    }

    get formattedTotal() {
        return fmt(this.totalDue);
    }

    // ── Event Handlers ─────────────────────────────────────────

    async handleOpen() {
        try {
            const [accountData, membershipProds, chapterProds, activeAsset] = await Promise.all([
                getCurrentUserPersonAccountInfo(),
                getMembershipProducts(),
                getChapterProducts(),
                getActiveMembershipAsset()
            ]);
            if (accountData) {
                console.log('[JoinFlow] accountData:', JSON.stringify(accountData));
                this.accountId           = accountData.accountId          || null;
                this.firstName           = accountData.firstName          || '';
                this.lastName            = accountData.lastName           || '';
                this.email               = accountData.email              || '';
                this.title               = accountData.title              || '';
                this.phone               = accountData.homePhone          || '';
                this.billingCountry      = accountData.billingCountryCode || 'US';
                this.billingStreet       = accountData.billingStreet      || '';
                this.billingCity         = accountData.billingCity        || '';
                this.billingState        = accountData.billingStateCode   || '';
                this.billingZip          = accountData.billingPostalCode  || '';
                this.region              = accountData.region             || '';
                this.shippingCountry         = accountData.shippingCountryCode || 'US';
                this.shippingStreet          = accountData.shippingStreet      || '';
                this.shippingCity            = accountData.shippingCity        || '';
                this.shippingState           = accountData.shippingStateCode   || '';
                this.shippingZip             = accountData.shippingPostalCode  || '';
                this.shippingSameAsBilling   = !accountData.shippingStreet;
                this.selectedCompanyId   = accountData.primaryAccountId   || null;
                this.selectedCompanyName = accountData.primaryAccountName || '';
                this.companySearchTerm   = accountData.primaryAccountName || '';
                this.jobFunction         = accountData.jobFunction        || '';
                this.orgType             = accountData.orgType            || '';
                this.yearsInIndustry     = accountData.yearsInIndustry    || '';
                this.primaryInterests    = accountData.primaryInterests   ? accountData.primaryInterests.split(';')  : [];
                this.programInterests    = accountData.programInterests   ? accountData.programInterests.split(';') : [];
                this.companyRole         = accountData.companyRole        || '';
                this.industrySector      = accountData.industrySector      || '';
                this.industrySectorOther = accountData.industrySectorOther || '';
                this.annualTravelSpend   = accountData.annualTravelSpend  || '';
                this.institution         = accountData.enrolledSchool     || '';
                this.academicInstitution = accountData.enrolledSchool     || '';
                this.graduationDate       = accountData.graduationDate     || '';
                this.globalPartnerLookup = accountData.globalPartnerLookup || '';
            }
            if (membershipProds) this.membershipProducts = membershipProds;
            if (chapterProds) this.chapterProducts = chapterProds;
            this.activeMembershipAsset = activeAsset || null;
            this.activeMembershipType  = activeAsset?.Type__c || '';
            console.log('Asset.Type__c:', activeAsset?.Type__c);
        } catch (e) {
            console.error('Join flow load error:', JSON.stringify(e));
        }
        this.isOpen = true;
    }

    async handleRenew() {
        this.isRenewing = true;
        this.renewError = '';
        try {
            const endDate = new Date();
            endDate.setFullYear(endDate.getFullYear() + 1);
            const orderId = await renewAssets({
                assetIds: [this.activeMembershipAsset.Id],
                renewEndDate: endDate.toISOString()
            });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: orderId, objectApiName: 'Order', actionName: 'view' }
            });
        } catch (e) {
            this.renewError = e?.body?.message || 'Renewal failed. Please try again.';
        } finally {
            this.isRenewing = false;
        }
    }

    handleClose() {
        this.isOpen = false;
    }

    handleNext() {
        if (this.currentStep === 0) {
            this.saveStep0AndProceed();
            return;
        }
        if (this.currentStep === 1) {
            this.saveStep1AndProceed();
            return;
        }
        if (this.currentStep === 2 && !this.showChapters) {
            this.currentStep = 5;
            return;
        }
        if (this.currentStep < STEP_LABELS.length - 1) {
            this.currentStep += 1;
        }
    }

    handlePrev() {
        if (this.currentStep === 5 && this.chapterOptOut) {
            this.currentStep = 3;
        } else if (this.currentStep === 5 && !this.showChapters) {
            this.currentStep = 2;
        } else if (this.currentStep > 0) {
            this.currentStep -= 1;
        }
    }

    handleOptOut() {
        this.chapterOptOut = true;
        this.selectedChapters = [];
        this.currentStep = 5;
    }

    async handleProceedToCheckout() {
        this.isPlacingOrder = true;
        this.orderError = '';
        try {
            const selectedChapterData = this.chapterProducts.filter(
                ch => this.selectedChapters.includes(ch.id)
            );
            const effShipCountry = this.shippingSameAsBilling ? this.billingCountry : this.shippingCountry;
            const effShipStreet  = this.shippingSameAsBilling ? this.billingStreet  : this.shippingStreet;
            const effShipCity    = this.shippingSameAsBilling ? this.billingCity    : this.shippingCity;
            const effShipState   = this.shippingSameAsBilling ? this.billingState   : this.shippingState;
            const effShipZip     = this.shippingSameAsBilling ? this.billingZip     : this.shippingZip;
            const orderId = await placeMembershipOrder({
                membershipProduct2Id: this.membershipProduct2Id,
                chapterProduct2Ids:   selectedChapterData.map(ch => ch.id),
                primaryChapterId:     this.primaryChapterId,
                billingCountryCode:   this.billingCountry,
                billingStreet:        this.billingStreet,
                billingCity:          this.billingCity,
                billingStateCode:     this.billingState,
                billingPostalCode:    this.billingZip,
                shippingCountryCode:  effShipCountry,
                shippingStreet:       effShipStreet,
                shippingCity:         effShipCity,
                shippingStateCode:    effShipState,
                shippingPostalCode:   effShipZip
            });
            if (orderId) {
                this.isOpen = false;
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId:      orderId,
                        objectApiName: 'Order',
                        actionName:    'view'
                    }
                });
            }
        } catch (e) {
            this.orderError = (e.body && e.body.message)
                ? e.body.message
                : 'An error occurred while placing your order. Please try again.';
            this.dispatchEvent(new ShowToastEvent({
                title:   'Order Error',
                message: this.orderError,
                variant: 'error'
            }));
        } finally {
            this.isPlacingOrder = false;
        }
    }

    // ── Step 0 handlers ────────────────────────────────────────

    handleInputChange(event) {
        const field = event.target.dataset.field;
        if (field) {
            this[field] = event.target.value;
            if (this.step0Errors[field]) {
                const updated = { ...this.step0Errors };
                delete updated[field];
                this.step0Errors = updated;
            }
        }
    }

    // ── Company search-ahead handlers ──────────────────────────

    handleCompanySearchInput(event) {
        const term = event.target.value;
        this.companySearchTerm   = term;
        this.selectedCompanyId   = null;
        this.selectedCompanyName = '';
        this.companySearchError  = '';

        if (this._companySearchTimer) clearTimeout(this._companySearchTimer);

        if (!term || term.trim().length < 2) {
            this.companySearchResults   = [];
            this.companyDropdownVisible = false;
            return;
        }
        this._companySearchTimer = setTimeout(() => {
            this._runCompanySearch(term.trim());
        }, 300);
    }

    async _runCompanySearch(term) {
        try {
            const results = await searchBusinessAccounts({ searchTerm: term });
            if (this.companySearchTerm.trim() !== term) return;
            this.companySearchResults   = results || [];
            this.companyDropdownVisible = this.companySearchResults.length > 0;
        } catch (e) {
            this.companySearchResults   = [];
            this.companyDropdownVisible = false;
            this.companySearchError     = 'Search failed. Please try again.';
        }
    }

    handleCompanyResultSelect(event) {
        const id   = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.selectedCompanyId      = id;
        this.selectedCompanyName    = name;
        this.companySearchTerm      = name;
        this.companyDropdownVisible = false;
        this.companySearchResults   = [];
        this.companySearchError     = '';
    }

    handleCompanySearchFocusOut() {
        setTimeout(() => { this.companyDropdownVisible = false; }, 150);
    }

    handleClearCompany() {
        this.selectedCompanyId      = null;
        this.selectedCompanyName    = '';
        this.companySearchTerm      = '';
        this.companySearchResults   = [];
        this.companyDropdownVisible = false;
        this.companySearchError     = '';
        this.companyMode            = 'search';
        this.newCompanyName         = '';
        this._clearAddressFields();
    }

    handleToggleCompanyMode() {
        this.companyMode            = this.companyMode === 'search' ? 'create' : 'search';
        this.companySearchTerm      = '';
        this.companySearchResults   = [];
        this.companyDropdownVisible = false;
        this.companySearchError     = '';
        this.newCompanyName         = '';
        this._clearAddressFields();
    }

    handleNewCompanyNameChange(event) { this.newCompanyName = event.target.value; }

    async handleCreateCompanySubmit() {
        if (!this.newCompanyName || !this.newCompanyName.trim()) {
            this.companySearchError = 'Company name is required.';
            return;
        }
        this.isCreatingCompany  = true;
        this.companySearchError = '';
        try {
            const newId = await createBusinessAccount({
                name:           this.newCompanyName.trim(),
                billingStreet:  this.newCompanyStreet,
                billingCity:    this.newCompanyCity,
                billingState:   this.newCompanyState,
                billingZip:     this.newCompanyZip,
                billingCountry: this.newCompanyCountry
            });
            this.selectedCompanyId   = newId;
            this.selectedCompanyName = this.newCompanyName.trim();
            this.companyMode         = 'search';
            this.newCompanyName      = '';
            this._clearAddressFields();
        } catch (e) {
            this.companySearchError = (e.body && e.body.message)
                ? e.body.message
                : 'Could not create company. Please try again.';
        } finally {
            this.isCreatingCompany = false;
        }
    }

    handleNewCompanyAddressChange(event) {
        const d = event.detail;
        this.newCompanyStreet  = d.street;
        this.newCompanyCity    = d.city;
        this.newCompanyState   = d.province;
        this.newCompanyZip     = d.postalCode;
        this.newCompanyCountry = d.country;
    }

    _clearAddressFields() {
        this.newCompanyStreet  = '';
        this.newCompanyCity    = '';
        this.newCompanyState   = '';
        this.newCompanyZip     = '';
        this.newCompanyCountry = 'US';
    }

    handleShippingSameAsBillingChange(event) {
        this.shippingSameAsBilling = event.target.checked;
    }

    handleBillingAddressChange(event) {
        const d = event.detail;
        this.billingStreet  = d.street;
        this.billingCity    = d.city;
        this.billingState   = d.province;
        this.billingZip     = d.postalCode;
        this.billingCountry = d.country;
    }

    handleShippingAddressChange(event) {
        const d = event.detail;
        this.shippingStreet  = d.street;
        this.shippingCity    = d.city;
        this.shippingState   = d.province;
        this.shippingZip     = d.postalCode;
        this.shippingCountry = d.country;
    }

    validateStep0() {
        const errors = {};
        if (!this.firstName.trim())  errors.firstName = 'First Name is required.';
        if (!this.lastName.trim())   errors.lastName  = 'Last Name is required.';
        if (!this.email.trim()) {
            errors.email = 'Email is required.';
        } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email.trim())) {
            errors.email = 'Please enter a valid email address.';
        }
        if (!this.title.trim()) errors.title = 'Title is required.';
        if (!this.phone.trim()) errors.phone = 'Home Phone is required.';

        const billingEl = this.template.querySelector('[data-id="billingAddress"]');
        const billingOk = billingEl ? billingEl.reportValidity() : true;
        let shippingOk = true;
        if (!this.shippingSameAsBilling) {
            const shippingEl = this.template.querySelector('[data-id="shippingAddress"]');
            shippingOk = shippingEl ? shippingEl.reportValidity() : true;
        }

        this.step0Errors = errors;
        return Object.keys(errors).length === 0 && billingOk && shippingOk;
    }

    async saveStep0AndProceed() {
        if (!this.validateStep0()) return;
        this.isSaving = true;
        this.step0SaveError = '';
        try {
            const shipCountry = this.shippingSameAsBilling ? this.billingCountry : this.shippingCountry;
            const shipStreet  = this.shippingSameAsBilling ? this.billingStreet  : this.shippingStreet;
            const shipCity    = this.shippingSameAsBilling ? this.billingCity    : this.shippingCity;
            const shipState   = this.shippingSameAsBilling ? this.billingState   : this.shippingState;
            const shipZip     = this.shippingSameAsBilling ? this.billingZip     : this.shippingZip;
            await savePersonAccountInfo({
                accountId:           this.accountId,
                firstName:           this.firstName,
                lastName:            this.lastName,
                email:               this.email,
                titleField:          this.title,
                homePhone:           this.phone,
                billingCountryCode:  this.billingCountry,
                billingStreet:       this.billingStreet,
                billingCity:         this.billingCity,
                billingStateCode:    this.billingState,
                billingPostalCode:   this.billingZip,
                primaryAccountId:    this.selectedCompanyId || null,
                shippingCountryCode: shipCountry,
                shippingStreet:      shipStreet,
                shippingCity:        shipCity,
                shippingStateCode:   shipState,
                shippingPostalCode:  shipZip
            });
            this.currentStep += 1;
        } catch (e) {
            this.step0SaveError = (e.body && e.body.message)
                ? e.body.message
                : 'An error occurred while saving. Please try again.';
        } finally {
            this.isSaving = false;
        }
    }

    async saveStep1AndProceed() {
        const errors = {};
        if (!this.jobFunction) errors.jobFunction = 'Please select a job function.';
        if (this.showOrgType && !this.orgType) errors.orgType = 'Please select an organization type.';
        if (this.showYearsInIndustry && !this.yearsInIndustry) errors.yearsInIndustry = 'Please select how many years you have worked in the industry.';
        if (this.isStudentRole && !this.institution) errors.institution = 'Please enter your institution.';
        if (this.isStudentRole && !this.graduationDate) errors.graduationDate = 'Please enter your anticipated graduation date.';
        this.step1Errors = errors;
        if (Object.keys(errors).length > 0) return;

        this.isSavingStep1 = true;
        this.step1SaveError = '';
        try {
            await saveQualificationInfo({
                accountId:           this.accountId,
                jobFunction:         this.jobFunction,
                orgType:             this.orgType,
                yearsInIndustry:     this.yearsInIndustry,
                primaryInterests:    this.primaryInterests.join(';'),
                programInterests:    this.programInterests.join(';'),
                companyRole:         this.companyRole,
                industrySector:      this.industrySector,
                industrySectorOther: this.industrySectorOther,
                annualTravelSpend:   this.annualTravelSpend,
                enrolledSchool:      this.institution,
                graduationDate:      this.graduationDate,
                academicInstitution: this.academicInstitution
            });
            const price = await getMembershipPriceFromMatrix({
                product2Id: this.membershipProduct2Id,
                region:     this.region
            });
            this.matrixPrice = price != null ? price : null;
            this.currentStep += 1;
        } catch (e) {
            this.step1SaveError = (e.body && e.body.message)
                ? e.body.message
                : 'An error occurred while saving. Please try again.';
        } finally {
            this.isSavingStep1 = false;
        }
    }

    // ── Step 1 handlers ────────────────────────────────────────

    handleJobFunctionChange(event) {
        this.jobFunction = event.target.value;
        this.orgType = '';
        this.industrySector = '';
        this.industrySectorOther = '';
        this.companyRole = '';
        this.annualTravelSpend = '';
    }
    handleOrgTypeChange(event)    { this.orgType = event.target.value; }
    handleYearsChange(event)      { this.yearsInIndustry = event.target.value; }

    handlePrimaryInterestToggle(event) {
        const value = event.target.dataset.value;
        this.primaryInterests = event.target.checked
            ? [...this.primaryInterests, value]
            : this.primaryInterests.filter(v => v !== value);
    }
    handlePrimarySelectAll(event) {
        this.primaryInterests = event.target.checked
            ? this.primaryInterestOptions.map(o => o.value)
            : [];
    }

    handleProgramInterestToggle(event) {
        const value = event.target.dataset.value;
        this.programInterests = event.target.checked
            ? [...this.programInterests, value]
            : this.programInterests.filter(v => v !== value);
    }
    handleProgramSelectAll(event) {
        this.programInterests = event.target.checked
            ? this.programInterestOptions.map(o => o.value)
            : [];
    }

    handleCompanyRoleChange(event)  { this.companyRole = event.target.value; }
    handleIndustrySectorChange(event) {
        this.industrySector = event.target.value;
        this.industrySectorOther = '';
    }
    handleOtherSectorChange(event)  { this.industrySectorOther = event.target.value; }
    handleAnnualSpendChange(event)  { this.annualTravelSpend = event.target.value; }
    handleInstitutionChange(event)       { this.institution = event.target.value; }
    handleGraduationDateChange(event)    { this.graduationDate = event.target.value; }
    handleAcademicInstitutionChange(event) { this.academicInstitution = event.target.value; }

    // ── Step 4 handlers ────────────────────────────────────────

    handleChapterToggle(event) {
        const id = event.target.dataset.id;
        if (this.selectedChapters.includes(id)) {
            const remaining = this.selectedChapters.filter((c) => c !== id);
            this.selectedChapters = remaining;
            if (this.primaryChapterId === id) {
                this.primaryChapterId = remaining[0] || null;
            }
        } else {
            this.selectedChapters = [...this.selectedChapters, id];
            if (this.selectedChapters.length === 1) {
                this.primaryChapterId = id;
            }
        }
    }

    handlePrimaryChapterChange(event) {
        this.primaryChapterId = event.target.dataset.id;
    }

    handleChapterSearch(event) {
        this.chapterSearchTerm = event.target.value;
        this.chapterPage = 0;
    }

    handlePageChange(event) {
        this.chapterPage = parseInt(event.currentTarget.dataset.page, 10);
    }
}