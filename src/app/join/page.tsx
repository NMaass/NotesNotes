import type { Metadata } from 'next';
import { OnboardingPage } from '@/components/onboarding/onboarding-page';
export const metadata:Metadata={title:'Start a journal'};
export default function Page(){return <OnboardingPage/>;}
